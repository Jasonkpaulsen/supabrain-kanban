# ADR-FAM-002: Agent ownership, operator grants and user-scoped execution for the Family Agent Gateway

- **Status:** Accepted (2026-09-07)
- **Ticket:** SB-418 · **Agent epic:** SB-417 (Family Agent Gateway) · **Data epic:** SB-406 (Family RLS MCP)
- **Builds on:** ADR-API-002 (`public.decisions.id = 78851c74-56c7-4520-805f-d44bc7164ecf`), ADR-FAM-001
- **Governs:** `public.agents`, `public.agent_projects`, `public.agent_skills`, `public.agent_runs`,
  `public.can_access_agent(uuid,uuid)`, `public.start_agent_run(uuid,uuid,uuid,text)`,
  `public.finish_agent_run(...)`, `public.assign_agent_to_item(uuid,uuid)`
- **Owner:** System Architect · **Implemented by:** Supabase Platform Engineer
- **Database copy:** `public.decisions`, title prefixed `ADR-FAM-002` (authoritative; this file mirrors it)

---

## 1. Context

Every agent row has `agents.user_id` = Jason. The policy `agents.members_select_via_project` returns
the **full** row (`system_prompt`, `mcp_tools`, `trigger_config`) to any project member through
`can_access_agent`. `start_agent_run`, `finish_agent_run` and `assign_agent_to_item` authorize by
ownership only, and the `agent_runs` INSERT policy checks only `user_id`.

Mandy (`auth.users.id 0dd94a9f-1890-48b0-9e4f-a4bbfff949f0`) must use eleven family agents from
Codex without owning them, without seeing their configuration, and without any agent widening her
data rights.

## 2. Decision

Ownership, operation and data authorization are **three separate concepts**.

1. **Ownership / configuration.** `agents.user_id` stays Jason. Only the owner or the governed
   platform path edits `system_prompt`, `mcp_tools`, `goals`, `constraints`, `reports_to_agent_id`,
   automation, `trigger_config` or skills. Agents are never cloned for Mandy.
2. **Operation.** `public.agent_operator_grants` (built by SB-419) authorizes a principal on a
   connection to use an agent: `external_connection_id`, `principal_user_id`, `agent_id`,
   `root_project_id`, `scope_mode ∈ {exact_project, member_descendants}`,
   `permissions ⊆ {view_profile, invoke, assign, delegate}`, `status ∈ {active, disabled, revoked}`,
   `expires_at`, `granted_by`. One active grant per (connection, principal, agent, root_project).
3. **Data.** Every tool call made while acting as an agent runs under Mandy's JWT and her RLS
   (ADR-API-002, SB-429). An agent cannot elevate table, row, project or write permissions.

**Visibility and invocation predicate**, evaluated on *every* call and not only at session start:

> active `external_connections` row for (`auth.uid()`, OAuth `client_id`)
> ∧ active, unexpired operator grant carrying the needed permission
> ∧ current `project_members` row for the requested project
>   (`exact_project` = that project only; `member_descendants` = the project is `root_project_id`
>   or a descendant of it in the projects tree *and* Mandy is a member of it)
> ∧ `agent_projects` row linking the agent to that project
> ∧ `agents.status = active`
> ∧ one published `agent_execution_profiles` row for the agent.

**To act as a role in Codex is the only v1 execution model.** `start_family_agent_session` returns a
sanitized role packet (profile id and version, display name, `role_instructions`, `guardrails`,
`allowed_family_tools`, project context, delegation targets, run id, trace id) and Mandy's own Codex
model performs the work using the Family Data MCP tools under her JWT. No server-side model is
invoked, no agent-row model or provider credential is read, and no run is ever represented as having
happened in the background. **Autonomous background execution** (JARVIS sweeps, Routines, agents with
`automation_enabled`) remains the internal path under ADR-API-001 and is not reachable through the
OAuth client.

## 3. Trust boundaries

| Zone | Components | Notes |
|---|---|---|
| Untrusted | Codex client, Mandy's session, tool arguments, all project data | Project data may carry prompt injection |
| Semi-trusted | Edge Function MCP | Evaluates the predicate, returns only published packets, writes audit rows, holds no `service_role` key |
| Trusted | Postgres, RLS, SECURITY DEFINER routines in a non-exposed schema | Enforcement point |
| Owner-only asset | the `agents` row | Never crosses the boundary; only the published profile does |

Prompt injection cannot change grants or profiles: the MCP exposes no tool that writes them. They
are written by the owner through migrations or `service_role` under the L3 gate.

## 4. Profile publication

`public.agent_execution_profiles` (SB-419): `agent_id`, `version`, `display_name`, `description`,
`role_instructions`, `guardrails text[]`, `allowed_family_tools text[]`, `delegation_policy jsonb`
(allowed child agent ids), `status ∈ {draft, published, retired}`, `published_by`, `published_at`,
`source_agent_updated_at`, timestamps. Unique `(agent_id, version)`; at most one published row per
agent via a partial unique index.

Content is curated by hand (SB-421, SB-423) from the source agent: mission, responsibilities,
constraints, delegation targets, allowed Family Data tools, escalation guidance, medical safety
language. A profile **never** contains `system_prompt` verbatim, `mcp_tools`, `trigger_config`, skill
config, credentials, private memories or owner-only governance text.

Source edits do not republish. Drift is flagged when `agents.updated_at` is later than
`source_agent_updated_at`; republication is a governed review that creates version+1 and retires the
previous version. Retired versions are kept so run history stays resolvable.

## 5. Grants

Seed (SB-421), all on the active Family Data connection from SB-408/SB-410 for principal
`0dd94a9f-1890-48b0-9e4f-a4bbfff949f0`:

| Agent | Permissions | Scope |
|---|---|---|
| Family PM (`1b5076df-9491-4ce4-a2f6-e9f2cd636aed`) | view_profile, invoke, assign, delegate | `member_descendants` rooted at Paulsen Family (`ed8cb7f7-a604-4054-a76e-c3e1114b5316`) |
| Family Care Manager, School & Activities Lead, Travel Coordinator | view_profile, invoke, assign, delegate | their approved project scope |
| Care Coordinator, EF Coach, Activities & Schedule Coordinator, School Monitor, Travel Planner, Travel Activities Coordinator | view_profile, invoke, assign | their approved project scope |
| Parent Advocate | view_profile, invoke, assign | output is draft-only; a parent sends |

Only agent/project intersections that also appear in Mandy's `project_members` rows are seeded; the
Jason Kurt Paulsen project is excluded. Family Finance Manager, Germany Legal Advisor, JARVIS, System
Architect, Platform Engineer, QA and every unlisted agent receive no grant, and a `family` tag grants
nothing. Effective access is the **intersection** of grant, membership and `agent_projects`; removing
any one removes access.

## 6. Delegation

The graph is explicit (SB-417):

- Family PM → Family Care Manager → Care Coordinator | EF Coach
- Family PM → School & Activities Lead → Activities & Schedule Coordinator | School Monitor
- Family PM → Parent Advocate
- Family PM → Travel Coordinator → Travel Planner | Travel Activities Coordinator

It is stored as `delegation_policy` on the parent's published profile and checked by
`delegate_family_agent_session`, which requires: the caller owns the parent run
(`agent_runs.user_id = auth.uid()`) and it is running; the parent grant carries `delegate`; the child
agent id is in the parent's `delegation_policy`; the child has its own active grant with `invoke` on
the same connection and principal; the child has an `agent_projects` row for the requested project;
the requester is a current member of that project. No upward, sideways, out-of-catalog or cross-user
delegation exists. A child run records `parent_run_id`, `delegated_by_agent_id`, the parent's
`trace_id` and the same `user_id`.

## 7. Run lifecycle

`agent_runs` gains explicit, indexed columns (SB-419): `operator_grant_id`, `oauth_client_id`,
`profile_id`, `profile_version`, `parent_run_id`, `delegated_by_agent_id`, `trace_id`,
`requested_project_id`, with `CHECK (parent_run_id <> id)`. The status domain gains `cancelled`
alongside `running`, `completed`, `failed`, `timeout`. Operator-started runs use `trigger_type
'manual'`; delegated runs use `'chain'`.

The routines `list_family_agents`, `get_family_agent_profile`, `start_family_agent_session`,
`delegate_family_agent_session`, `complete_family_agent_session`, `list_my_family_agent_sessions` and
`assign_family_agent_to_work_item` (SB-420, SB-422) are SECURITY DEFINER, live in schema
`family_gateway` (not exposed to PostgREST), set `search_path = ''`, read `auth.uid()` internally,
take no `p_user_id` argument, are executable only by `authenticated`, and each re-evaluates the full
predicate.

Direct INSERT or UPDATE on `agent_runs`, `agents`, `agent_projects` and `agent_skills` through the
OAuth client is denied by RESTRICTIVE policies keyed on the `client_id` claim (SB-420). Jason's
existing owner path through `start_agent_run` and `finish_agent_run` is unchanged. Concurrency: at
most `agents.max_concurrent_tasks` (default 5) running runs per agent per principal.

`assign_family_agent_to_work_item` requires the `assign` permission, a work item Mandy can update
under SB-429 RLS, and an `agent_projects` row for the item's project. `assign_agent_to_item` is
amended by SB-420 to accept the item owner *or* an editor member instead of the owner alone.

## 8. Revocation

Each takes effect on the next call.

1. Grant status `disabled` or `revoked`, or `expires_at` passed → that agent disappears.
2. `project_members` row removed → that project scope disappears for every agent.
3. `external_connections` status `disabled` or `revoked` → every agent tool returns 401.
4. Profile retired with no published successor → invoke fails until a new version is published.
5. OAuth token or client revocation as in ADR-API-002.

Running runs under a revoked grant are marked `cancelled` by `complete_family_agent_session` on the
next touch or by the daily sweep. Revocation never deletes run history.

## 9. Medical safeguards

Family Care Manager and Care Coordinator organise information, summarise records, prepare questions
for clinicians and record instructions a parent or provider has confirmed. They do **not** diagnose,
prescribe, choose or change dosages, or replace clinicians. That language is carried in `guardrails[]`
of their published profiles and enforced server-side: any `medications` insert or update made inside
an agent session requires `confirm = true` on the call and writes a `care_audit_log` row carrying
`run_id` and `profile_version`. When urgent symptoms are described, the profile directs the agent to
advise contacting emergency or clinical services and to stop acting as clinical support.

EF Coach provides educational and executive-function support, not treatment. Parent Advocate drafts
communications; sending is a human action outside the MCP. `health_providers.portal_secret_ref` and
every secret-like field are excluded by the SB-408 catalog deny list and never appear in a packet or a
tool result.

## 10. Rollback

- **Grants:** set status `revoked` (history kept) or delete the rows.
- **Profiles:** retire.
- **Routines:** `drop schema family_gateway cascade`.
- **`agent_runs` columns:** additive and nullable; drop after archiving the rows' values into
  `run_metadata`.
- **RESTRICTIVE policies:** drop.

Owner behaviour is unchanged at every step, so partial rollback is safe. Each implementing migration
(SB-419, SB-420, SB-421) records its DROP script on its own ticket, as SB-408 and SB-429 did.

## 11. Alternatives considered

| Alternative | Why rejected |
|---|---|
| Clone the eleven agents with `agents.user_id` = Mandy | Forks configuration, doubles governance, guardrails drift |
| Keep membership-based SELECT on `agents` as the access model | Exposes `system_prompt` and `mcp_tools`; SB-420 removes it for the OAuth client |
| Server-side autonomous execution with the agent row's model and provider credentials | New credential surface; unattended writes to child medical data |
| Tag-based inheritance (any agent tagged `family` is usable) | Implicit, unauditable, admits future agents silently |

## 12. Consequences

- SB-419 builds the structures exactly as named here; SB-420 the RESTRICTIVE policies and routines;
  SB-421 the profiles and grants; SB-422 the MCP tools; SB-423 the source-prompt audit.
- `public.can_access_agent(p_agent_id, p_user_id)` accepts an arbitrary `p_user_id` and is replaced
  on the operator path by `auth.uid()`-bound checks in SB-420.
