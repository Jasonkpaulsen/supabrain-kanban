# ADR-API-002: End-user Codex access uses Supabase Auth OAuth 2.1 + RLS, not the hosted Supabase MCP (narrows ADR-API-001)

- **Status:** Accepted (2026-09-06)
- **Ticket:** SB-407 · **Epic:** SB-406 (Family RLS MCP) · **Related epic:** SB-417 (Family Agent Gateway)
- **Narrows:** ADR-API-001 (`public.decisions.id = ee35c097-eaf9-45d3-9fa4-f1b2fcf03b22`) — does not replace it
- **Related:** ADR-APP-001 (`c4e93e97-e31a-4a77-b9bc-6b4b7fc8bd5a`), ADR-PLAT-001 (`44ca7510-dc9d-49ac-ad5b-59c9d4ac4ea8`)
- **Domain:** api_integration · **Owner:** System Architect · **Implemented by:** Supabase Platform Engineer
- **Database copy:** `public.decisions`, title prefixed `ADR-API-002` (the database row is authoritative; this file mirrors it)

---

## 1. Context

ADR-API-001 makes the hosted Supabase MCP the universal agent-to-database layer, and it runs with
`service_role`, which bypasses RLS and exposes `execute_sql`, schema inspection and migrations. That is
correct for trusted internal agents and wrong for a human end user.

Mandy (`auth.users.id 0dd94a9f-1890-48b0-9e4f-a4bbfff949f0`) holds editor membership on 7 shared
family projects and needs to work on them from Codex. Until SB-429 (2026-09-06) the four core kanban
tables were owner-only, so membership granted nothing; that is now fixed at the RLS layer and this ADR
builds on it.

## 2. Decision

1. Internal trusted platform agents keep using the hosted Supabase MCP under ADR-API-001 governance.
2. Human end users use a **separate custom MCP server** authenticated with the end user's own
   Supabase Auth OAuth 2.1 token. v1 principal: Mandy only.
3. The server is a **Streamable HTTP Supabase Edge Function**.
4. A **pre-registered OAuth client** is used. Dynamic Client Registration stays disabled for this
   one-person rollout.
5. Authorization is the **intersection** of: (a) an active connection row for
   `(auth.uid(), OAuth client_id)`; (b) an explicit resource/action grant; (c) current project
   membership and role in `public.project_members`; (d) table RLS; (e) a fixed MCP tool allowlist.
   OAuth identity scopes never grant table access.
6. The server exposes **named business tools only**. It never exposes `execute_sql`, arbitrary table
   selection, schema inspection, migrations, edge-function deployment, Auth administration, Storage
   administration, or service-role credentials. No service-role key or database password is present
   in its environment.
7. v1 resources and actions are exactly the matrix in §6. **DELETE is out of scope.**
8. A future table is not exposed by adding its name. It requires an owner-approved grant, a
   registered server-side handler, RLS coverage, and QA evidence.

## 3. Trust boundary

| Zone | Components | Notes |
|---|---|---|
| Untrusted | Codex client, model output, every tool argument, anything from Mandy's session | Treated as hostile input |
| Semi-trusted | The Edge Function | Validates the JWT, enforces allowlist and grants, filters fields, writes audit. Holds no credential stronger than Mandy's own token |
| Trusted | Supabase Auth, Postgres with RLS, the Edge runtime | Enforcement point is the database |

The database never sees any principal other than role `authenticated` with `sub` = Mandy's uid for
this path.

## 4. Data flow

1. Mandy adds the server URL in Codex. Codex discovers the OAuth metadata and completes
   authorization-code + PKCE against Supabase Auth. The token carries `aud=authenticated`,
   `sub=<her uid>`, and the `client_id` claim.
2. Each tool call carries the bearer token. The server verifies signature, expiry, `aud` and
   `client_id`, then looks up the active connection row for `(sub, client_id)`. Missing or revoked
   → 401, logged.
3. The tool name is checked against the allowlist and the `(resource, action)` grant table → else
   403, logged.
4. The handler runs a parameterized PostgREST call **with Mandy's JWT**, so RLS applies. Write tools
   require an explicit `confirm` argument. The response passes through a field filter before return.
5. An audit row is written for every call: `sub`, `client_id`, tool, resource, affected ids, outcome.

## 5. Threat model

| Threat | Control |
|---|---|
| Token theft or replay | Short-lived access tokens, refresh rotation, connection-row revocation, `aud` and `client_id` checks |
| Prompt injection driving a destructive call | No DELETE, SQL or schema tools exist; writes need `confirm`; allowlist fixed at deploy time |
| Confused deputy (server acting with its own authority) | Server has no `service_role`; all data access runs under Mandy's JWT |
| Horizontal escalation across projects | RLS keyed to `project_members` (SB-429) plus the RESTRICTIVE `client_id` guard (SB-409) |
| Sensitive field exposure (`health_providers.portal_secret_ref`, any secret-like field) | Handler field filter plus column-level REVOKE or view (SB-409); never present in tool output |
| Scope creep by table name | Rule 8 |
| Agent execution exceeding the user's rights | Every agent tool action runs under Mandy's JWT (SB-417) |
| Server compromise | Blast radius bounded by Mandy's RLS rights; audit trail; revocation path (§8) |

## 6. v1 resource/action matrix

R = read, C = create, U = update. **No D anywhere.**

| Resource | R | C | U | Notes |
|---|:-:|:-:|:-:|---|
| projects | ✓ | | | |
| project_members | ✓ | | | |
| work_items | ✓ | ✓ | ✓ | |
| work_item_comments | ✓ | ✓ | own | Editors edit only their own comments |
| labels | ✓ | ✓ | ✓ | |
| work_item_labels | ✓ | ✓ | | Removing a label is a DELETE → owner only |
| activities | ✓ | ✓ | ✓ | |
| behavioral_logs | ✓ | ✓ | ✓ | |
| care_plans | ✓ | ✓ | ✓ | |
| family_events | ✓ | ✓ | ✓ | |
| health_events | ✓ | ✓ | ✓ | |
| health_providers | ✓ | ✓ | ✓ | `portal_secret_ref` excluded |
| medications | ✓ | ✓ | ✓ | |
| school_assignments | ✓ | ✓ | ✓ | |
| care_audit_log | ✓ | | | Read-only |

Not exposed in v1: `memories`, `decisions`, agents configuration, Family Finance, anything not listed.

## 7. Default-deny rule

A call that is not in the allowlist, not covered by a grant, not inside a project where Mandy is a
current member, or not permitted by RLS is denied and logged. The server ships with an **empty grant
table**; grants are inserted by Jason under the L3 gate.

## 8. Revocation path

1. **Immediate:** mark the connection row revoked (or remove the `project_members` row) → the next
   call fails within one request.
2. **Auth:** revoke the user's refresh tokens for the client; access-token expiry (≤ 1 h) bounds the
   residual window.
3. **Full:** disable the OAuth client.

Epic completion requires a **revoke-and-reconnect drill** before the production connection is called
live.

## 9. Rollback

- **Connector:** redeploy the previous Edge Function version or delete the function; no data changes.
- **Grants:** delete the rows.
- **RLS (SB-429):** independent of the connector — it also serves the web dashboard — and stays. Its
  own rollback is recorded on SB-429 and in migration `sb429_membership_rls_core_kanban`.

## 10. Scope amendment — family medical data and agent operators

- Mandy is an authorized parent operator for family and child medical data in her member projects.
- Approved medical resources: `activities`, `behavioral_logs`, `care_plans`, `family_events`,
  `health_events`, `health_providers`, `medications`, `school_assignments`. `care_audit_log` is
  read-only.
- `health_providers.portal_secret_ref` and all secret-like fields are never returned.
- Database agent ownership remains with Jason. Mandy receives operator/invocation grants, not
  ownership or configuration rights.
- v1 agent execution uses Mandy's current Codex session as the execution engine with a versioned,
  sanitized agent profile. It does not launch an ungoverned background model.
- Every agent tool action executes under Mandy's JWT and therefore cannot exceed her RLS rights.
- Family PM delegation is limited to explicitly granted descendant agents assigned to projects where
  Mandy is a current member.

## 11. Alternatives considered

| Alternative | Why rejected |
|---|---|
| Give Mandy the hosted Supabase MCP | `service_role` bypasses RLS and exposes SQL/schema/migration tools |
| Shared service account with application-level ACLs in the connector | Confused deputy; the connector would hold authority greater than the user |
| Direct PostgREST access from Codex with a long-lived personal token | No tool allowlist, no field filtering, no per-call audit |
| Enable Dynamic Client Registration | Adds registration attack surface for a one-person rollout, no benefit |

## 12. Consequences

- SB-429 is the PERMISSIVE base; SB-409 adds RESTRICTIVE `client_id` guards on top. Order matters.
- The seven family `FOR ALL` policies already grant membership access but carry no role test; a
  follow-up ticket role-gates them.
- `assign_agent_to_item` and `start_agent_run` still check `work_items.user_id = auth.uid()`; SB-420
  replaces that with membership.
