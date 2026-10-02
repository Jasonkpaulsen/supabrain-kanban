# ADR-CRM-002: CRM engagement layer — interactions, follow-ups, signals

- **Status:** Accepted (System Architect, 2026-10-02)
- **Epic:** SB-457 (CRM — Engagement History & Follow-Up)
- **Build tickets:** SB-460 (interactions), SB-459 (follow-up actions), SB-458 (signals and review queries)
- **Builds on:** ADR-CRM-001. Every rule there (owned-table standard, composite same-owner FKs,
  provenance, sensitivity, audit) applies here unchanged.

## 1. Decision in one paragraph

An interaction is one row, whatever its kind: a call, meeting, email, message, meal, event, gift,
introduction or note. The people and organizations involved are its participants, any number of
them. A follow-up is a `crm_actions` row linked to a person, an organization, an interaction, or
any combination. Signals (last contact, next contact due, overdue actions, upcoming dates) are
**derived in views from data the user entered**. There is no stored score, and every flag comes
with the inputs and a plain-language explanation that produced it.

## 2. Tables

**`crm_interactions` (SB-460)**
- `interaction_type`: call / meeting / email / message / meal / event / gift / introduction /
  note / other.
- `direction`: inbound / outbound / mutual. Nullable, because a note or a meal has no direction.
- `occurred_at` (required), `ended_at` (≥ `occurred_at`), `title`, `summary`, `location`.
- `sensitivity` with the ADR-CRM-001 §5 classes, default `normal`, never inferred.
- Provenance columns, the archive convention, and `meta`.
- `occurred_at` may be in the future (a scheduled meeting). Signals only count interactions that
  have happened.

**`crm_interaction_participants` (SB-460)**
- Exactly one of `person_id` / `organization_id`, enforced by a check.
- Composite FKs to the interaction, the person and the organization.
- `role`: participant / organizer / sender / recipient / introducer / introduced / giver /
  receiver / other.
- A person or organization appears at most once per interaction.

**`crm_actions` (SB-459)**
- `title`, `notes`, `status` (open / done / cancelled), `priority` (urgent / high / normal /
  low), `due_at`, `completed_at`, `sensitivity`.
- Optional links `person_id`, `organization_id`, `interaction_id`; **at least one is required**.
- `completed_at` is set if and only if the status is `done`. A trigger stamps it when the status
  becomes `done` and clears it on reopen; a check enforces it.
- `public.crm_create_follow_up(interaction_id, title, due_at, priority, person_id, sensitivity)`
  is how an interaction creates its next action:
  - It is SECURITY INVOKER, so it can only see the caller's own interaction.
  - It links the interaction.
  - It defaults the person to the interaction's only person participant, when there is exactly
    one.
  - It defaults `sensitivity` to the **interaction's** class. Copying a class a human already
    chose is not inference; it stops a follow-up from leaking a sensitive interaction at a lower
    class. An explicit argument overrides it.

**Cadence and priority on `crm_people` (SB-458)**
- `contact_cadence_days` (1–3650): "I want to be in touch at least every N days".
- `relationship_priority` (1 = highest … 5).
- Both are user-set and nullable. There is deliberately **no score column**: SB-458 says opaque
  AI scores must not be canonical.

## 3. Signals and review (SB-458)

All of these are `security_invoker` views or invoker-rights functions, so RLS decides what
exists for the caller.

- `crm_contact_signals`: one row per live person, with:
  - `last_contact_at` and `last_contact_type`: the latest non-archived interaction the person
    took part in, with `occurred_at <= now()`.
  - `days_since_contact`.
  - `next_contact_due_at`: last contact + cadence. When there is a cadence but no contact yet,
    it is the date the person was added.
  - `is_contact_overdue` and `days_overdue`.
  - Open, overdue and next-due action counts and dates.
  - The next important date (`crm_next_occurrence`).
  - `explanation`: the same inputs as one sentence, for example "cadence 30d; last contact
    2026-08-18 (call, 45 days ago); 15 days past cadence; 1 overdue action".
- `crm_review_stale_relationships`: overdue people, ordered by priority, then days overdue.
- `crm_review_overdue_actions`: open actions past `due_at`, ordered by priority, then age.
  Titles of restricted actions (sensitive / highly_sensitive) show as `(restricted)`, so the
  review queue is safe to hand to an agent.
- `crm_upcoming_dates(within_days default 30, from date default today)`: birthdays,
  anniversaries and other dates in the window, with `days_until` and `years`. `years` is the age
  or anniversary count when the year is known.

## 4. Agent retrieval and the restricted-read convention

- `crm_interactions_for_agent(person_id, include_restricted default false, reason default null)`
  mirrors `crm_facts_for_agent`:
  - normal and private only by default;
  - restricted classes need a snake_case reason code and are audited before any row returns.
- It returns type, direction, time, title and summary.
- **Convention, applied to both functions from this ADR on:** a `restricted_read` audit row has:
  - `entity_type` = the table that was read (`crm_facts` or `crm_interactions`);
  - `entity_id` = the person whose records were read;
  - `entity_count` = the number of restricted rows.

  `crm_facts_for_agent` is redefined to follow this convention. It previously used
  `crm_people`, which would have made fact reads and interaction reads indistinguishable in the
  audit log.

## 5. Not in scope

- Inbox or calendar sync. That is SB-474 (integration).
- AI recommendations and briefings. That is SB-470, and SB-473 must read through the
  `*_for_agent` functions.
- No UI, and no seeded interactions.
