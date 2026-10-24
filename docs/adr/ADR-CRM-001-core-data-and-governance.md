# ADR-CRM-001: Personal CRM core data layer and governance

- **Status:** Accepted (System Architect, 2026-10-01)
- **Epics:** SB-452 (CRM Core), SB-461 (CRM Privacy, Security & Data Governance)
- **Build tickets:** SB-453, SB-454, SB-455, SB-456 (core); SB-462, SB-463, SB-464, SB-465 (governance)
- **Later epics that build on this:** SB-457 (engagement), SB-466 (search / data quality), SB-470 (agent intelligence), SB-474 (import / export)

## 1. Decision in one paragraph

There is one canonical person row per human, `crm_people`. Family, friend and business are
**relationship contexts** (`crm_person_relationships`, `crm_affiliations`, `crm_groups`), never
separate person tables. Every CRM row belongs to exactly one owner (`user_id`), and the database,
not the client, guarantees that child rows only ever point at rows of the **same owner**.
Governance is part of the schema from the first migration, not a later layer:
- every fact-bearing row carries provenance;
- free-form personal facts carry a sensitivity class;
- the audit log is append-only and cannot hold row bodies.

## 2. Conventions every CRM table follows

| Concern | Rule |
|---|---|
| Keys | `id uuid primary key default gen_random_uuid()` |
| Ownership | `user_id uuid not null default auth.uid() references auth.users(id) on delete cascade` |
| Timestamps | `created_at`, `updated_at` (`public.update_updated_at()` trigger) |
| Archive | House convention `archived boolean not null default false`, plus `archived_at`, stamped by trigger. Normal workflows archive; hard delete is allowed but audited. |
| Extensibility | `meta jsonb not null default '{}'`, for source/extension data only. Core fields stay relational. |
| Enumerations | `CHECK` constraints on short text codes. They are cheap and visible in the schema, with no lookup-table joins. |

### 2.1 Same-owner integrity (composite foreign keys)

A plain FK is checked as the table owner and **bypasses RLS**. With a plain FK, user B could
attach a row to user A's person just by knowing its UUID, and could probe whether a UUID exists
from the FK error. To prevent that:
- every parent carries `unique (id, user_id)`;
- every child references `(parent_id, user_id)`.

A cross-owner link is then impossible at the database level, whoever the caller is, including
`service_role`.

### 2.2 Provenance (SB-463)

Every fact-bearing table (people, contact points, addresses, relationships, organizations,
affiliations, important dates, facts) carries these columns:

| Column | Meaning |
|---|---|
| `source_type` | `manual` / `import` / `agent` / `sync`, default `manual` |
| `source_ref` | Free text: file name, connector id, agent name. Never a credential. |
| `captured_at` | When the fact was captured |
| `confidence` | `numeric(3,2)`, 0–1. **Required** when `source_type <> 'manual'`. |
| `confirmed_at` | When a human confirmed the fact |
| `is_confirmed` | Generated: `source_type = 'manual' or confirmed_at is not null` |

Low-confidence and unconfirmed facts are therefore distinguishable by a column, not by
convention. Archive preserves references because nothing cascades on `archived`.

## 3. Tables

**Core (SB-453):**
- `crm_people`: `display_name` is the only required field besides ownership. Also holds given,
  family, middle and preferred names, and `pronouns`. Dates such as birthdays live in
  `crm_important_dates`, not on the person.
- `crm_contact_points`: `kind` is one of email / phone / handle / url / other. `value` is stored
  as given. `value_normalized` is generated: email lowercase-trimmed, phone reduced to digits and
  a leading +, others lowercase-trimmed. Also `label`, `is_preferred`, `is_current`,
  `valid_from`, `valid_until`. Unique on `(person_id, kind, value_normalized)`; an old value is
  set `is_current = false`, not deleted. A partial unique index allows at most one preferred,
  current, unarchived point per person and kind.
- `crm_addresses`: label, lines, city, region, postal code, ISO country; the same
  preferred/current/validity history rules.

**Relationships (SB-454):**
- `crm_relationship_types`:
  - Global rows (`user_id is null`) are seeded by migration and read-only to clients. Custom rows
    are owned.
  - Each type has `code`, `label`, `inverse_label`, `is_symmetric`, and `category`
    (family / social / professional / other).
- `crm_person_relationships`:
  - A row reads **"`person_id` is the `label` of `related_person_id`"**.
  - Symmetric types are stored once, in canonical order `person_id < related_person_id`, which a
    trigger enforces, so there is no duplicate pair.
  - Other columns: validity dates, `context`, `closeness` 1–5, `priority`, provenance.
  - A trigger rejects a type the row's owner cannot see.
- `crm_relationships_expanded` (view, `security_invoker`):
  - Gives every relationship from both sides: `(person_id, other_person_id, other_is)`.
  - Parent/child therefore queries correctly from either end without storing two rows.

**Organizations (SB-455):**
- `crm_organizations`: type is one of company / school / club / household / vendor / community /
  government / other.
- `crm_affiliations`: role/title, department, start and end dates, and a generated `is_current`
  (`end_date is null`). A partial index serves "current affiliations of X". Organization data is
  never copied onto the person.

**Groups, tags, dates (SB-456):**
- `crm_groups` and `crm_group_members`: circles such as Family, Close Friends, ELC, Vendors,
  School Parents, or custom.
- `crm_tags` and `crm_entity_tags`: a tag points at exactly one person **or** organization
  (check constraint), with composite FKs on both.
- `crm_important_dates`:
  - Stores `month`, `day` and an optional `year`, so a birthday without a year is representable.
  - `kind` is one of birthday / anniversary / milestone / memorial / other.
  - `recurrence` is none / yearly.
  - `public.crm_next_occurrence()` maps Feb 29 to Feb 28 in common years.

**Governance:**
- `crm_facts` (SB-463, SB-464): an extensible person fact or note, with `fact_type`, `value`,
  provenance, and **`sensitivity`**.
- `crm_audit_log` (SB-462): append-only.

## 4. Access control (SB-465)

- RLS is enabled on every CRM table, with **one policy per command**.
- Every policy is `to authenticated` and tests `user_id = (select auth.uid())`. `TO authenticated`
  is never the whole test.
- UPDATE has both `USING` and `WITH CHECK`, so a row cannot be handed to another owner.
- Grants are explicit (SB-488 removed the defaults): `select, insert, update, delete` to
  `authenticated`, nothing to `anon`.
- Exceptions:
  - `crm_audit_log` is `select, insert` only, plus an append-only trigger.
  - `crm_relationship_types` lets clients see global rows but change only their own.
- **Future shared access** (approved membership) is added as an *additional permissive policy*.
  Policies are OR-ed, so the owner policies here never need rewriting.
  `highly_sensitive` facts must stay excluded from any membership policy.

## 5. Sensitivity and agent retrieval (SB-464)

- Classes: `normal` (default), `private`, `sensitive`, `highly_sensitive`.
- Nothing infers a class: there are no triggers, classifiers or defaults beyond `normal`.
  Classification is always a human act.
- **Restricted** = `sensitive` and `highly_sensitive`.
- General agent retrieval goes through `public.crm_facts_for_agent(person_id)`. It is
  `SECURITY INVOKER`, so RLS still applies, and returns `normal` and `private` only.
- Reaching restricted classes requires the explicit call
  `crm_facts_for_agent(person_id, include_restricted => true, reason => 'snake_case_code')`. A
  missing or free-text reason raises. The reason is a code, not prose, so the audit log cannot
  become a place for content. Every such call writes a `restricted_read` audit row **before**
  returning data.
- SB-460 (interactions) must adopt the same `sensitivity` column and the same retrieval rule.

## 6. Audit (SB-462)

`crm_audit_log` columns:
- `user_id` (the data owner)
- `actor_id` (`auth.uid()`; null for `service_role`)
- `actor_kind` (user / agent / system)
- `action` (merge / export / bulk_import / sensitivity_change / delete / archive / unarchive /
  restricted_read)
- `entity_type`, `entity_id`, `entity_count`
- `outcome` (succeeded / failed / denied)
- `reason_code`, `created_at`

There is **deliberately no column able to hold a value, a note, a name or a payload** (the
SB-412 rule). `user_id` has no FK, so audit survives account deletion and cannot block it.

Automatic rows:
- every hard delete of a CRM entity row;
- every archive and unarchive;
- every sensitivity change;
- every restricted read.

Merge (SB-467), export (SB-476) and bulk import (SB-477) are later tickets. They call
`public.crm_audit(...)`, which is invoker-rights, so the caller can only write rows attributed to
themselves.

## 7. What this deliberately does not do

- No CRM UI. This is the data layer.
- No interactions, follow-ups, search, dedupe, import or export. Those are the later epics, and
  the hooks for them are named above.
- No seeded people or groups. Tests run inside rolled-back transactions, with invented names.
- No automatic sensitivity inference.
