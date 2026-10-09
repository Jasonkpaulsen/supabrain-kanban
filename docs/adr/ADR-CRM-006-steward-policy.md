# ADR-CRM-006: CRM steward policy: source tiers, policy confirmation, automatic merge

- **Status:** Accepted (System Architect, 2026-10-07). Jason approved the policy on 2026-10-07
  (SB-569 decisions e, f, g: Tier A auto-confirm, auto-merge with undo, a CRM Data Steward agent).
- **Epic:** SB-570 (CRM — Population and autonomous stewardship)
- **Tickets:** SB-571 (this ADR), SB-572 (unmerge), SB-573 (steward run), SB-574 (digest),
  SB-575 (QA sampling), SB-576 (steward agent), SB-577 (internal loader), SB-578 (address book),
  SB-579 (calendar), SB-580 (memories)
- **Amends:** ADR-CRM-001 §2.2 (`confirmed_at` meant "a human confirmed") and ADR-CRM-003 §1
  ("nothing is ever merged automatically"). Every other rule in ADR-CRM-001..005 applies
  unchanged.

## 1. Decision in one paragraph

Jason does not want to clear duplicate and unconfirmed queues by hand. The steward therefore
decides routine cases **by written policy**:
- **Trust.** Every CRM row's trust tier follows from its provenance (`source_type`,
  `source_ref`).
- **Confirmation.** Tier A rows are confirmed by policy, Tier B rows after a quiet period,
  and Tier C rows only when a second source agrees.
- **Merges.** Duplicates that meet a strict rule are merged automatically, and every merge can
  be undone.

Each automatic decision is written to an append-only decision log with a rule and a reason code.
That log feeds the weekly digest and the QA sample. Jason sees only exceptions.

## 2. Source trust tiers

The tier is computed, never stored, by `crm_source_tier(source_type, source_ref)` (immutable):

| Tier | Meaning | Provenance that maps to it |
|---|---|---|
| **A** | Jason-authored | `source_type = 'manual'`; or `source_ref` starts with `apple_contacts`, `vcard`, `google_contacts`, `outlook`, `csv` (Jason's own address-book exports), or is `manual_json:household` |
| **B** | Structured system data that Jason's agents keep | `source_ref` starts with `manual_json:openbrain.` (the internal loader, §6) |
| **C** | Inferred | everything else: calendar (`google_calendar`, `outlook_calendar`), `source_type = 'agent'`, any other `manual_json` label |

Notes:
- The import contract (ADR-CRM-005 §3.1) is unchanged. Internal sources use `manual_json` with
  a reserved label instead of new source values, so `crm_import_contacts` is not rewritten.
  Reserved labels are `household` and `openbrain.<table>`.
- **Accepted risk.** Every caller of the import door is the signed-in owner, Jason or an agent
  acting as Jason, so a reserved label is trusted as declared. Adapters are told which label
  they may use, and the steward agent's skill names only Tier C labels. A mislabeled Tier A
  import is the same risk as Jason typing the row by hand.
- **Address books.** Apple Contacts is the master (Jason, 2026-10-07). It arrives as a vCard
  (`vcard` or `apple_contacts`). The other address-book sources are Tier A for the day Jason
  exports them himself.

## 3. Confirmation by policy (amends ADR-CRM-001 §2.2)

`confirmed_at` now means "confirmed by a person **or by a written policy**". Which one is
recorded in the row's `meta.confirmed_by`:
- `'user'`: a person confirmed it. This is also what `confirmed_at` means when `meta` has no
  key, so existing rows keep their meaning.
- `'policy:tier_a'`: Tier A, confirmed on load.
- `'policy:tier_b_14d'`: Tier B, confirmed 14 days after capture if nothing contradicts it.
- `'policy:tier_c_corroborated'`: Tier C, confirmed when an independent source agrees.

`is_confirmed` is unchanged. A policy-confirmed row is confirmed for every reader. Agents and
humans who need to tell the two kinds apart read `meta.confirmed_by`.

| Rule | When | Applies to |
|---|---|---|
| `tier_a` | at load, by the loader or the steward run | the person and its child rows that carry the same Tier A `source_ref` and are unconfirmed |
| `tier_b_14d` | steward run, `captured_at` ≥ 14 days ago | Tier B rows with no **open** import conflict on the person and no open duplicate pair |
| `tier_c_corroborated` | steward run | a Tier C contact point or fact whose normalized value also exists on the same person from a different source tier |
| `tier_c_expire` | steward run, `captured_at` ≥ 60 days ago and still unconfirmed | Tier C rows are **archived** (recoverable), never deleted |

What policy never does:
- **Sensitivity.** It never changes a sensitivity class (ADR-CRM-001 §5 holds: nothing infers
  sensitivity).
- **Restricted rows.** It never confirms a `sensitive` or `highly_sensitive` row.
- **Owner edits.** It never touches a row the owner edited after capture, that is, when
  `updated_at` is more than a minute after `captured_at` and the edit was not made by policy.

The primitive is `crm_policy_confirm_person(person_id, policy)`. It is SECURITY INVOKER: the
owner only, under RLS. SB-577 builds it with the `tier_a` policy; SB-573 adds the others.

## 4. Automatic merge (amends ADR-CRM-003 §1)

**The rule.** A pair is merged automatically only when **all** of these hold:
1. Both people are live: not archived and not merged.
2. Either:
   - they share a normalized email **and** their names are compatible (same `family_name`, or
     one `name_normalized` contains the other), **or**
   - they share a normalized phone **and** their names are compatible as above **and** their
     given names are compatible (`crm_given_names_compatible`; SB-583: a shared phone plus the
     same surname is two relatives as often as one person), **or**
   - their `name_normalized` values are equal **and** they share a live affiliation to the
     same organization.
3. Neither has a `sensitive` or `highly_sensitive` fact, interaction or action (restricted data
   is never moved without a person).
4. The pair is not in `crm_duplicate_dismissals`.
5. Auto-merge is not suspended (§7).

**Which person is kept**, in order:
1. the higher tier;
2. the confirmed one;
3. the one with more interactions;
4. the older `created_at`.

The merge uses `crm_merge_people` unchanged, with reason code `auto_merge_contact` or
`auto_merge_name_org`.

**Undo is a precondition.** `crm_merge_log.moved` holds per-table **counts** today
(ADR-CRM-003 §5), so a merge cannot be undone yet.
- SB-572 changes `crm_merge_people` to also record the moved row ids per table
  (`crm_merge_log.undo`, §4.1), and builds `crm_unmerge(merge_log_id, reason)`.
- `crm_unmerge` refuses when any moved row changed after the merge.
- Merges made before SB-572 have no ids and are not undoable. That is acceptable: none have
  been made, because the CRM was empty until this epic.
- **The steward does not auto-merge until SB-572 is shipped.**

### 4.1 Undo (SB-572)

**What a merge records.** `crm_merge_people` keeps its behaviour. It also writes
`crm_merge_log.undo` (jsonb), which holds ids, flags and row fingerprints only, no names or values:
- `moved`: per `table.column`, the ids of the rows moved, and whether the move cleared
  `is_preferred` to avoid a clash;
- `kept`: per table, the ids of rows that could not move and were archived on the merged
  person, with their archived state before the merge;
- `filled`: the names of the person fields filled on the kept person from the merged person.

The values themselves are not copied: the merged person's row still holds them.

**Undo.** `crm_unmerge(merge_log_id, reason)` runs as the owner (SECURITY INVOKER, RLS) and
undoes the merge exactly, or refuses and changes nothing.

It **refuses** (`55000`) when:
- the merge has no `undo` record;
- the merge is already undone;
- the kept person is archived or merged since;
- the merged person is no longer archived as merged into the kept person;
- any moved or kept row has changed since the merge. Each recorded row carries `fp`, the md5
  of the row (without `updated_at`) as the merge left it. A fingerprint holds no readable
  content and catches every change, even one made in the same transaction, where `now()`
  does not move;
- a filled field no longer equals the merged person's value, that is, the owner edited it.

When nothing refuses, it:
1. moves every recorded row back, restoring `is_preferred` where the merge cleared it;
2. unarchives only the rows the merge archived;
3. clears the filled fields;
4. brings the merged person back as a live person (`archived = false`, `merged_into_id = null`).

Rows added to the kept person after the merge stay where they are.

**Records.**
- `crm_unmerges` (append-only, one row per merge log id) records the undo: who, when, reason
  code and counts.
- The pair gets a `crm_duplicate_dismissals` row (`unmerged`), so neither the steward nor the
  duplicate list proposes the same merge again.
- Archive and unarchive are audited by the existing row triggers. `crm_audit_log`'s
  caller-recordable actions are unchanged, so no constraint has to be dropped.
- An undone automatic merge counts as a wrong merge for the QA suspension threshold (SB-575).
  This is read from `crm_unmerges` joined to `crm_steward_decisions.merge_log_id`.

### 4.2 The steward run (SB-573)

`crm_steward_run(p_dry_run boolean default false, p_limit int default 200)` returns a summary
as jsonb. It runs as the owner (SECURITY INVOKER, RLS).

**Phases, in this order.** Each phase only sees what the earlier ones left:
1. **Resolve import conflicts** by the §5 table. Tier A against Tier A stays open. A
   `took_incoming` resolution stamps `meta.confirmed_by = 'policy:auto_resolve'` on the row it
   wrote. Same-tier birthdays keep the existing value: a newer date is not more likely right.
2. **Auto-merge** pairs from `crm_duplicate_candidates(1000)` that meet the §4 rule. Rule (a)
   uses email or phone only; handles do not count. Keeper order as in §4. Each merge is one
   `auto_merge` decision carrying its `merge_log_id`. A merge that raises is skipped and
   counted; it never stops the run. Skipped entirely while auto-merge is suspended.
3. **Dismiss gray-zone pairs.** A `possible` candidate qualifies when:
   - it has no shared organization, group or relationship;
   - both people were created at least 30 days ago.
   The pair is dismissed with `crm_dismiss_duplicate(…, 'auto_dismiss_gray_zone')` and logged
   as `auto_dismiss`. Pairs that do share context are left for the digest.
4. **Confirm.**
   - `tier_a`: Tier A people not yet confirmed.
   - `tier_b_14d`: Tier B people captured at least 14 days ago with no open import conflict and
     no duplicate candidate.
   - `tier_c_corroborated`: Tier C facts whose fact type and value also appear on the same
     person from a different source.
   All three go through `crm_policy_confirm_person`, which now also takes `tier_b_14d` and
   re-checks its conditions itself.
5. **Expire.** Tier C facts and interactions that are still unconfirmed 60 days after capture
   are archived (`auto_expire`). Restricted rows are never touched by any phase.

**Bounds and switches:**
- **Per-run limit:** at most `p_limit` decisions, capped at 200; the summary says when the cap
  was hit.
- **Kill switch:** a non-dry run needs an active agent named `CRM Data Steward`, owned by the
  caller, with `automation_enabled = true`. Otherwise it returns `{disabled: true}` and changes
  nothing.
- **Dry run:** always allowed. It does the whole run inside a savepoint, rolls it back, and
  returns what would have happened.
- **Suspension:** auto-merge is suspended while the newest `suspend`/`resume` row in the
  decision log is a `suspend`.
- **Run id:** every decision row carries the run's `run_id`.

**Scheduling** belongs to the steward agent (SB-576). The run never executes as `postgres`,
because RLS and `auth.uid()` need a real owner.

> **Amendment (SB-576, 2026-10-08).** The schedule is a pg_cron job, `crm-steward-daily`, at
> `20 10 * * *` UTC. The job does not run the steward as `postgres`. Inside one DO block it:
> 1. sets `request.jwt.claims` to the owner, taking the owner from the `CRM Data Steward`
>    agent row so the job holds no literal id;
> 2. runs `SET LOCAL ROLE authenticated`, which is exactly what an API call with the owner's
>    JWT gets;
> 3. calls `crm_steward_scheduled('daily')`.
>
> That wrapper (SECURITY INVOKER, pinned search_path, closed to anon):
> - is a no-op while the agent is missing, not `active`, or has `automation_enabled = false`;
> - otherwise calls `crm_steward_run(false, 200)`;
> - writes one `agent_runs` row (`trigger_type = 'scheduled'`, summary in `run_metadata`). A
>   raised error becomes a `failed` run, not an aborted job;
> - updates the agent's `last_run_at`, `run_count`, `error_count` and `last_error`.
>
> No cron command names `crm_steward_run` directly (asserted in the migration).
> SB-575/SB-574 add a `weekly` task to the same wrapper.

**Tier C scope today:** facts (corroborate and expire) and interactions (expire). The CRM has no
Tier C contact points: calendar import never creates them, and agents propose facts.

**Gray zone.** Similar names with no shared identifier (the trigram candidates of ADR-CRM-003
§4):
- A pair is dismissed automatically after 30 days if nothing links the two people.
- It goes to Jason only when the two share an organization, a group or a relationship.

## 5. Import conflicts

The steward resolves a conflict with `crm_resolve_import_conflict`. The rule is decided by the
tiers of the existing value and the incoming value:

| Situation | Resolution | Reason code |
|---|---|---|
| Incoming tier is higher than the existing tier | `took_incoming` | `auto_resolve_higher_tier` |
| Incoming tier is lower | `kept_existing` | `auto_resolve_lower_tier` |
| Same tier, contact or role field | `took_incoming` (newer wins) | `auto_resolve_newer` |
| Same tier, a name field | `kept_existing` | `auto_resolve_keep_name` |
| Tier A against Tier A | **left open, to Jason** | — |

## 6. Internal loader (SB-577)

One-time load, and safe to re-run, of data already in OpenBrain. It goes only through
`crm_import_contacts`, using source `manual_json` and these labels:

| Label | Source rows | Mapped as | Group |
|---|---|---|---|
| `household` | the owner, plus each child project (a `family` project used as `child_project_id`) | people; relationships: owner `parent` of each child; the children are `sibling`s | Household |
| `openbrain.condo_contacts` | condo contacts, not archived | person; organization = the condo project's name before " — "; title = the board office when `relationship` names one, else the role (Owner, Co-owner, Tenant) | Condo |
| `openbrain.school_courses` | teacher and co-teacher of each course, one person per teacher (by email, else by name) | person; organization = `school`; title Teacher or Co-teacher; relationship teacher `teacher` of the child | School |
| `openbrain.health_providers` | providers | person; organization; **no title, no specialty, no notes, no link to a child** (SB-569 §3) | Care |
| `openbrain.employer_details` | supervisors | person; organization = employer; title Supervisor; the employer's phone is **not** given to the person | Work |

Rules:
- **Owner only.** Each builder reads only the caller's own rows (`user_id = auth.uid()`), so
  one user's data never reaches another user's CRM. Employer details in OpenBrain today belong
  to another account, so Jason's load creates no Work people.
- **No PII in code.** Builders read names at run time. The owner's own name is a run-time
  argument, never a literal in a migration.
- **Self-match.** A Tier B record whose `name_normalized` exactly equals a live **household**
  person's name is not created as a new person. Its affiliation and group are added to the
  household person instead. This rule is exact, not fuzzy, and limited to the household set.
  It stops the owner from appearing twice, as himself and as a condo owner.
- **Writes outside the contract.** Groups, group members and relationships are not part of the
  import contract. The loader writes them as the owner, under RLS:
  - find-or-create, so a re-run changes nothing;
  - `source_type 'import'`, `confidence 0.90`, `source_ref` = the label.
- **Household confirmation.** Household people are Tier A and are confirmed by policy
  `tier_a` as soon as they load.
- **External ids** are `<table>:<id>`. A teacher's is `school_courses:teacher:<md5 of email or
  name>`, so a teacher who teaches two courses is one person. The household uses
  `household:owner` and `household:child:<project id>`.
- **Out of scope:** job applications (organizations without people), notes, mailing addresses
  (the contract has no address field), and the free-text kinship in `condo_contacts.relationship`
  (for example "X's mother"; left for the owner).
- **Relationship ownership.** Relationships with the owner (parent, manager) are written only
  when the owner's household person exists.

## 7. Decision log, QA sampling and the kill switch

`crm_steward_decisions` is an owner-scoped, **append-only** table, protected by
`crm_append_only` the way `crm_merge_log` is. It holds one row per automatic decision:
- `decision`: `auto_confirm`, `auto_merge`, `auto_resolve`, `auto_expire`, `auto_dismiss`;
- `rule`: for example `tier_a` or `auto_merge_contact`;
- `entity_type`, `entity_id`;
- `reason_code`;
- `merge_log_id`, which is the undo handle;
- `run_id`;
- `sampled_at`, `qa_verdict`, written by the QA sampling job through its own append-only
  verdict row, not an update.

It holds **no names or values**. SB-577 creates the table because the household's Tier A
confirmation is its first writer.

Automatic decisions go in this log, not in `crm_audit_log`. The audit log's caller-recordable
actions (`merge`, `export`, `bulk_import`, `restricted_read`, `agent_read`) are unchanged.
A merge still writes its own `merge` audit row through `crm_merge_people`.

**Kill switch and limits:**
- The steward job runs only while the CRM Data Steward agent's `automation_enabled` is true.
- Each run handles at most 200 decisions (SB-573).

**QA sampling (SB-575):**
- Each week, 10 automatic decisions are sampled.
- If the wrong-merge rate over the last 50 sampled merges goes above **2%**, auto-merge is
  suspended. The suspension is a row in the decision log (`decision = 'suspend'`), and it holds
  until Jason or QA writes a `resume` row.

## 8. What still goes to Jason (weekly digest, SB-574, target under 5 items)

- sensitivity classification;
- anything that touches restricted data;
- Tier A against Tier A conflicts;
- gray-zone pairs that share an organization, a group or a relationship;
- a suspension of auto-merge;
- for information only, no action: that week's automatic merges with their undo handles.

## 9. Consequences

- `is_confirmed` stops meaning "a person looked at it". Anything that must know uses
  `meta.confirmed_by`. The agent surfaces (ADR-CRM-004) pass it through, so an agent can say
  "on file, confirmed by policy".
- **Order is binding:**
  1. SB-577 creates the decision log and Tier A confirmation.
  2. SB-572 (undo) must ship before SB-573 turns on auto-merge.
  3. SB-575 must ship before the first week of auto-merge ends.
