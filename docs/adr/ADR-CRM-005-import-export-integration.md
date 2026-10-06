# ADR-CRM-005: CRM import, export and external-source integration

- **Status:** Accepted (System Architect, 2026-10-06)
- **Epic:** SB-474 (CRM — Import, Export & External Integration Foundation), approved
- **Tickets:** SB-475 (integration spike), SB-477 (import contract), SB-476 (export)
- **Builds on:** ADR-CRM-001 (conventions, provenance, sensitivity, audit) and ADR-CRM-003
  (normalized contact values, reviewed merge). Their rules apply unchanged.

## 1. Decision in one paragraph

Outside data enters the CRM through **one door**: a versioned JSON contract
(`crm.contacts.v1`, `crm.interactions.v1`) accepted by two functions that run as the signed-in
owner. They:
- validate every record;
- remember each source's own id, so repeating an import changes nothing;
- add what is missing and **never overwrite or remove** what is already there.

A disagreement between the CRM and the source becomes a reviewable conflict row, not an edit.
Everything imported carries `source_type = 'import'`, a `source_ref` and a confidence, and stays
unconfirmed until a person confirms it.

Data leaves through **one function**, `crm_export`. It returns the owner's whole CRM as one
versioned JSON document, excludes restricted data unless asked by reason code, and is audited.

No connector is built in this epic. Sync is inbound only: nothing is ever written back to
Google, Apple or Microsoft.

## 2. Integration spike (SB-475)

### 2.1 Recommendation matrix

| Source | Realistic access path | Consent and credentials | Constraints | Direction | Recommendation |
|---|---|---|---|---|---|
| **Apple Contacts** | No web API. iCloud CardDAV needs an app-specific password; Contacts.app exports vCard (`.vcf`). | CardDAV means storing an account password, so it is **rejected**. A vCard export is a deliberate act by the user. | vCard 3/4 field drift; photos dropped. | In | **Now:** vCard file → `crm.contacts.v1` (converter outside the DB). No CardDAV. |
| **Google Contacts** | People API, scope `contacts.readonly`; incremental `syncToken`. Google Takeout/CSV as a no-API fallback. | OAuth, read-only scope; the token lives in the adapter, never in the CRM. | A sync token expires after about 7 days (full resync); per-user quotas. | In | **Next:** read-only adapter that posts `crm.contacts.v1`; external id = People `resourceName`. CSV export works today. |
| **Outlook / Microsoft 365** | Graph `/me/contacts` with delta query, scope `Contacts.Read`. | OAuth; a work tenant may require admin consent. | Delta tokens; separate personal and work accounts. | In | **Later:** same adapter shape as Google; vCard/CSV export today. |
| **Calendar (Google)** | Events with attendee emails (a Calendar connector already exists in this workspace). | Already granted for scheduling. | Attendees are other people's addresses; most events are not relationship moments. | In, as **unconfirmed** interactions | **Next:** `crm.interactions.v1`. Attendees are linked **only** to people who already exist (by normalized email). Never create a person from an attendee. |
| **Email (Gmail)** | Gmail API; `gmail.readonly` is a *restricted* scope. | High: bodies and subjects carry third parties' content. | Restricted-scope review for any public app. | — | **Deferred.** If ever built: per-contact last-contacted dates from headers only; no bodies, and no subjects stored. Needs a separate decision. |

### 2.2 Rules every adapter follows

1. **Inbound only.** The CRM never edits, deletes or creates anything in an external system.
2. **No credentials in the CRM.** OAuth tokens and passwords live with the adapter. `source_ref`
   and `source_label` hold names (an account label, a file name), never a secret (ADR-CRM-001 §2.2).
3. **Same door as a person.** An adapter calls `crm_import_contacts` / `crm_import_interactions`
   as the owner, with a user JWT. It is never `service_role`, and it never writes a `crm_*`
   table directly, so RLS, validation and provenance always apply. This is the epic's
   acceptance criterion "external data never bypasses CRM rules".
4. **Imports never classify.** Imported rows get the default `normal` class (ADR-CRM-001 §5:
   nothing infers sensitivity). Free-text notes are imported only when the payload asks
   (`include_notes`), so the default import carries no prose.
5. **Absence is not deletion.** A contact missing from a later import is left alone.

## 3. Import contract (SB-477)

### 3.1 Payload `crm.contacts.v1`

```json
{
  "format": "crm.contacts.v1",
  "source": "vcard | csv | google_contacts | outlook | apple_contacts | manual_json",
  "source_label": "optional: account or file name, ≤ 200 chars, never a credential",
  "include_notes": false,
  "records": [{
    "external_id": "required, ≤ 200 chars, stable per source",
    "display_name": "optional if given/family present",
    "given_name": "", "middle_name": "", "family_name": "", "preferred_name": "",
    "emails":  [{"value": "a@b.example", "label": "work", "preferred": true}],
    "phones":  [{"value": "+1 555 0100", "label": "mobile"}],
    "handles": [{"value": "@someone"}], "urls": [{"value": "https://…"}],
    "organization": {"name": "", "title": "", "department": ""},
    "birthday": {"month": 4, "day": 9, "year": 1990},
    "notes": "imported only when include_notes is true"
  }]
}
```

At most **1,000 records per call**, so large imports are batched. Bounds are the table
bounds:
- given, middle, family and preferred names ≤ 100 characters; display name ≤ 200;
- contact values ≤ 320, labels ≤ 50;
- organization name ≤ 200; title and department ≤ 150;
- notes ≤ 4,000;
- birthday year 1800–2200.

### 3.2 Payload `crm.interactions.v1`

```json
{
  "format": "crm.interactions.v1",
  "source": "google_calendar | outlook_calendar | manual_json",
  "source_label": "…",
  "records": [{
    "external_id": "required (calendar event id + start)",
    "interaction_type": "meeting | call | event | …",
    "occurred_at": "ISO 8601", "ended_at": "ISO 8601 or null",
    "title": "≤ 200", "location": "≤ 200",
    "participant_emails": ["a@b.example"]
  }]
}
```

An interaction is created only when **at least one participant email matches an existing live
person**. The others are ignored and never stored. Imported interactions are unconfirmed
(`confidence` 0.60).

### 3.3 Tables (owned-table standard, `crm_secure_owned_table`)

| Table | Purpose |
|---|---|
| `crm_import_batches` | One row per call: source, format, label, counts (received, created, updated, linked, unchanged, conflicts, rejected), `reason_code`, timestamps. Holds no record content. |
| `crm_external_ids` | `(source, external_id) → entity`: entity type `crm_people` or `crm_interactions`, the entity id, the first and last batch, and a hash of the last payload. One live row per `(user_id, source, external_id)`. |
| `crm_import_conflicts` | Person, field, existing value, incoming value, batch, status (`open`, `kept_existing`, `took_incoming`, `dismissed`). One row per `(person, field, incoming value)`, whatever its status, so a conflict already resolved is never raised again by the same value. |

The foreign keys are composite `(id, user_id)` (ADR-CRM-001 §2.1). A conflict holds a contact
person's own name or role. That is person data, owner-only under RLS, and it never goes in the
audit log.

### 3.4 Matching, in order

1. **External id.** `(source, external_id)` already maps to a person; a merged person is
   followed through `merged_into_id`.
2. **Unique contact match.** Exactly one live person has a normalized email or phone in the
   record. The id is linked and counted as `linked`.
3. **Otherwise a new person** (`source_type 'import'`, confidence 0.90, `source_ref`
   `<source>:<label>`). If several people matched in step 2, the import does not guess: it
   creates a new person, and the shared contact value surfaces it as a `possible_duplicate`
   recommendation (ADR-CRM-004) for a reviewed merge (ADR-CRM-003).

### 3.5 Field rules: additive, never destructive

| Field | Existing empty | Equal | Different |
|---|---|---|---|
| given / middle / family / preferred name | fill it | nothing | **conflict** |
| display name | (always present) | nothing | **conflict** |
| email / phone / handle / url | add a contact point | nothing (same normalized value) | add it as another point; nothing is removed |
| organization | find or create the organization by normalized name, and add an affiliation if none is live | nothing | role differs → **conflict** `role_title@<org id>` |
| birthday | add the important date | nothing | **conflict** `birthday` |
| notes (`include_notes`) | add a fact `imported_note` | the same text already exists → nothing | — |

When a record's hash equals the last-seen hash for its external id, it is `unchanged` and
skipped. All other paths are find-or-create, so a repeated import is idempotent even without
the hash.

`crm_resolve_import_conflict(id, resolution)` handles conflicts:
- `kept_existing` and `dismissed` only close the row.
- `took_incoming` writes the incoming value, as a human-confirmed edit (`confirmed_at = now()`),
  for the person-name fields, role title and birthday.

### 3.6 Validation

A record is rejected, counted, and reported back by **index and error code only** (never its
values) when:
- `external_id` is missing or too long;
- no display name can be derived;
- an email does not look like `x@y.z`;
- the birthday is impossible;
- a field exceeds its bound.

An unknown `format` or `source`, a missing or prose `reason`, or more than 1,000 records rejects
the whole call (`22023`). An unauthenticated caller gets `42501`. One rejected record never
aborts its batch.

### 3.7 Audit

Each call writes **one** `bulk_import` row: entity `crm_import_batches`/batch id,
`entity_count` = records received, and the reason code. Nothing about the records goes in it.

## 4. Export (SB-476)

```
crm_export(p_reason text, p_include_restricted boolean default false,
           p_include_archived boolean default false) → jsonb
```

- **Format `crm.export.v1`.**
  - Top level: `exported_at`, `counts`, `omitted`.
  - `people[]`, each with nested `contact_points`, `addresses`, `important_dates`, `facts`,
    `tags` and `groups`.
  - `organizations[]`, `affiliations[]`, `relationships[]` (with type code and label).
  - `interactions[]` with nested `participants`; `actions[]`.
  - Every row keeps its id and its provenance fields.
- **Ownership.** SECURITY INVOKER plus an explicit `user_id = auth.uid()` on every source. A
  caller with no user session gets `42501`, never an empty "success".
- **Restricted data** (`sensitive`, `highly_sensitive` facts, interactions and actions) is left
  out and counted in `omitted`, unless `p_include_restricted`. Including it writes an extra
  `restricted_read` audit row.
- **Archived** rows, which include merged people, are left out unless `p_include_archived`.
- **Audit.** One `export` row, written before the document is returned: entity `crm_people`,
  `entity_count` = people exported, plus the reason code.
- **User-initiated only.** `crm_export` is not an agent surface. It is not named `*_for_agent`,
  so it stays outside the ADR-CRM-004 §2.1 set (assertion A5 pins that set). Agents use the
  per-person surfaces.
- **Bounds.** Refuses (`54000`) above 25,000 live people, so a runaway owner gets an error, not
  an out-of-memory. Target: under 5 s at the ADR-CRM-003 §6 scale (5,000 people).

## 5. Not in scope

- The adapters themselves (vCard and CSV converters, Google and Microsoft OAuth clients). Each
  is a separate ticket that posts the contracts above.
- Re-importing an export (`crm.export.v1` → import) and two-way sync.
- Email ingestion (§2.1, deferred) and attachment or photo import.
