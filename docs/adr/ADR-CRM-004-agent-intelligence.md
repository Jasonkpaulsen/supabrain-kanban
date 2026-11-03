# ADR-CRM-004: CRM agent intelligence — retrieval contract, briefings, recommendations

- **Status:** Accepted (System Architect, 2026-10-04)
- **Epic:** SB-470 (CRM — Agent Intelligence & Relationship Briefings), approved
- **Build tickets:** SB-473 (retrieval contract), SB-472 (briefing), SB-471 (recommendations)
- **Builds on:** ADR-CRM-001, -002, -003. Their rules apply unchanged; in particular the
  sensitivity classes (ADR-CRM-001 §5) and the restricted-read convention (ADR-CRM-002 §4).

## 1. Decision in one paragraph

Agents get three new read surfaces and nothing else new:
- a least-privilege **person card**;
- a bounded, source-aware **briefing** on one person;
- a list of **explainable recommendations** that a person can dismiss.

Every agent read of a person is reason-coded and written to the audit log. Restricted data
(`sensitive`, `highly_sensitive`) never appears in any of them; it stays behind the existing
explicit `*_for_agent(include_restricted => true, reason)` calls. Contact values (addresses,
numbers, handles) are never returned to an agent. Nothing here sends a message, schedules
one, or writes anything except an audit row or a dismissal.

## 2. The retrieval contract (SB-473)

### 2.1 Surfaces an agent may use

| Surface | Returns | Restricted data | Audited |
|---|---|---|---|
| `crm_person_card_for_agent(person, reason)` | identity, cadence, priority, contact *kinds* and which kinds are marked preferred | never | `agent_read` |
| `crm_briefing(person, reason)` | §3 | never; counts of what was omitted | `agent_read` |
| `crm_recommendations(max)` | §4 | never (restricted titles masked) | no (no per-person content) |
| `crm_facts_for_agent(person[, true, reason])` | facts | only with `include_restricted` + reason | `restricted_read` when restricted |
| `crm_interactions_for_agent(person[, true, reason])` | interactions | same | same |
| `crm_search(query)` | names, match field | never (ADR-CRM-003 §3) | no |
| `crm_upcoming_dates(...)`, `crm_review_stale_relationships`, `crm_review_overdue_actions`, `crm_duplicate_candidates(...)` | review queues | restricted action titles masked | no |

Agents do not select from `crm_*` tables directly, and do not read `crm_contact_points.value`.

### 2.2 Rules every surface follows

1. **SECURITY INVOKER**, so the caller's RLS applies, **plus** an explicit
   `user_id = auth.uid()` filter. A caller with RLS bypassed (service role) gets nothing.
   Running with owner rights is not used (see ADR-CRM-003 §6, an open decision).
2. **Reason codes.** The per-person surfaces require `reason`, a snake_case code of 3–64
   characters (`meeting_prep`, `weekly_review`). Prose or a missing reason raises `22023`.
   The code is the only free-ish text in the audit row; it cannot carry content.
3. **Audit before data.** `agent_read` is written before the result is returned, with:
   `actor_kind = 'agent'`, `entity_type = 'crm_people'`, `entity_id` = the person,
   `entity_count` = the number of items returned, and the reason code. If the audit insert
   fails, nothing is returned.
4. **Not found means not found.** An unknown, archived, merged or someone else's person raises
   `P0002` with the same message, so a caller cannot probe for existence.
5. **Least privilege.** A surface returns what its task needs. The card returns contact *kinds*
   and which kinds have a preferred entry ("has a preferred email"), never the value. Free text is truncated (280
   characters) and lists are capped (§3).
6. **No inference.** Nothing classifies sensitivity, infers traits, or labels a relationship.
   Stored relationships or facts that a human has not confirmed are returned with
   `confirmed: false` and their `source_type`, never presented as fact.

### 2.3 Audit vocabulary

`crm_audit_log.action` gains `agent_read`. `crm_audit()` accepts it from callers (like
`restricted_read`, it is recorded by the read function, not by a trigger).

### 2.4 Enforcement (asserted in the migration and re-checked by the suite)

- Every `crm_*` view is `security_invoker`.
- Every `crm_*` function that `authenticated` can execute is SECURITY INVOKER. The one
  SECURITY DEFINER function, the audit trigger `crm_audit_row_event`, is not executable by
  `authenticated`.
- `anon` can execute no `crm_*` function and read no `crm_*` relation.
- The set of functions named `*_for_agent` is exactly the set listed in §2.1.

## 3. Briefing (SB-472)

```
crm_briefing(person_id uuid, reason text) → jsonb
```

| Section | Content | Bound |
|---|---|---|
| `person` | names, pronouns, priority, cadence, `confirmed`, contact kinds, preferred kinds | 1 |
| `signals` | last contact, days since, overdue, the `crm_contact_signals` explanation | 1 |
| `relationships` | the other person's name and how they relate, closeness, context, `confirmed`, `source_type`; live and in-date only | 20 |
| `affiliations` | organization, role, current or past, `confirmed`, `source_type` | 10 |
| `recent_interactions` | type, direction, when, title, summary (≤280); happened already; normal/private only | 5 |
| `open_follow_ups` | title (`(restricted)` when restricted), due, priority, `overdue` | 10 |
| `upcoming_dates` | kind, label, next date, days until, years | 60 days, 5 |
| `facts` | type, value (≤280), `confirmed`, `source_type`, `confidence`; normal/private only | 20 |
| `omitted` | counts of restricted facts, restricted interactions, and items cut by each bound | — |

Every item carries its row `id`, so an agent can cite where a statement came from. The
`omitted` counts make the bounds visible: a briefing never silently implies it is complete.

## 4. Recommendations (SB-471)

```
crm_recommendations(max_results int default 50)
  → kind, subject_key, person_id, display_name, title, reason, source_ids jsonb, rank
crm_dismiss_recommendation(kind, subject_key, reason default 'not_useful', until date default null) → uuid
```

| Kind | From | Reason text, for example | `subject_key` |
|---|---|---|---|
| `overdue_follow_up` | open actions past due | "follow-up 'Send photos' was due 2026-09-30 (4 days ago)" | `<action>:<due date>` |
| `contact_gap` | `crm_contact_signals` overdue | the signals explanation | `<person>:<due date>` |
| `upcoming_date` | `crm_upcoming_dates(14)` | "birthday in 5 days (turns 40)" | `<date row>:<occurrence>` |
| `possible_duplicate` | the same normalized email, phone or handle on two live people | "shares an email address with Robin Oakhurst" (the kind, never the value) | `<a>:<b>` (canonical order) |
| `unconfirmed_fact` | agent- or import-sourced facts not confirmed; normal/private only | "agent-added fact 'employer_guess' (confidence 0.50) is unconfirmed" | `<fact>` |
| `no_contact_method` | a person with a cadence but no current contact point | "cadence 30 days but no way to contact them is recorded" | `<person>` |

Rules:
- **Keys expire with their circumstances.** A dismissal hides one key. A follow-up moved to a
  new due date, a new contact gap, or next year's birthday has a new key and is shown again.
- `crm_recommendation_dismissals` is an owned table (ADR-CRM-001 standard): one live row per
  key, a reason code, an optional `until` date (snooze). Archiving it un-dismisses.
- Restricted action titles show as `(restricted)`; restricted facts are never listed.
- `rank` orders the list and is never stored: overdue follow-ups, then contact gaps, then
  dates, then data hygiene; within a kind, the most urgent first.
- **Nothing is sent.** `crm_recommendations` is STABLE, so it cannot write. No trigger, cron
  job or function in the CRM references `net.http_*` or sends anything; the suite asserts it.
- Performance: under 1 s at the ADR-CRM-003 §6 scale (5,000 people). **Measured
  2026-10-04** (`supabase/tests/crm_agent_perf.sql`): median 182 ms; a briefing 76 ms.
- **Known behaviour of the ranking:** kinds are strictly ordered, so a large backlog of one
  kind fills the list first. In the performance dataset, 1,000 overdue follow-ups filled the
  whole top 500. That is deliberate (overdue commitments first), and `max_results` up to 500
  plus dismissals keep it workable. Interleaving kinds is a possible later refinement.

Duplicate detection here is the cheap, strong signal only (shared identifiers). The full
similar-name scan stays in `crm_duplicate_candidates`, which takes about 2 s at that scale.

## 5. Not in scope

- Natural-language generation. These functions assemble facts; writing the prose briefing is
  the agent's job, from this data, citing the ids.
- Any outreach, drafting or scheduling. Sending stays separately user-approved.
- Restricted data in briefings or recommendations. An agent that needs it makes the explicit,
  reason-coded `*_for_agent` call, which is audited as `restricted_read`.
