# ADR-FLOW-003 — Work-item archival convention & mechanism

- **Status:** Proposed (awaiting sign-off)
- **Ticket:** SB-313 (DESIGN)
- **Downstream build ticket:** SB-314 (BUILD)
- **Domain:** infrastructure
- **Supersedes / relates to:** ADR-FLOW-001 (WIP limits), ADR-FLOW-002 (review + approval gates on `done`), ADR-COMP-001 (governance audit trail)
- **Revision:** rev 2 (2026-08-10) — revised after System Architect and Process Engineer review of
  rev 1. Ten defects fixed: the view-vs-client filter contradiction (§4.1), a third unscoped
  frontend (§4.1), the re-open trap that stranded rows permanently (§4.4), the missing run identity
  that made rollback impossible (§4.5), an incorrect L2 "standing approval" claim (§5), a schedule
  collision (§5), the unviable null-`completed_at` deferral (§4.2), an unnecessary index (§4.2), an
  epic-exclusion spec conflict (§5), and the false claim that operational views are unaffected
  (§4.1). Retention changed from a flat 30 days to a 14/60-day two-tier policy per Jason.

---

## 1. Context

The JARVIS morning sweep on 2026-08-09 flagged **691 `done` tickets older than 7 days** inflating the
board. `work_items` has no archival mechanism: every row ever created is still rendered.

Jason directed (2026-08-09) that this be designed by the Process Engineer *with* the System
Architect rather than executed as a one-off bulk mutation.

### Corrections to the premise recorded on SB-313

Two statements in the ticket description are out of date and the design should not be built on them:

1. **"work_items has only six statuses."** The live CHECK constraint allows **nine**:
   `backlog, todo, in_progress, review, done, escalated, blocked, on_hold, awaiting_jason`.
2. **"No established meta convention."** There *is* an established house convention — a boolean
   `archived` column defaulting to `false`. It already exists on **12 tables**: `projects`,
   `decisions`, `memories`, `conversations`, `image_assets`, `reference_items`, `skills`,
   `test_cases`, `trade_signals`, `condo_units`, `condo_contacts`, `school_assignments`.
   The frontend already consumes it: `index.html:544` fetches
   `projects?select=...,archived&archived=eq.false`.

`work_items` is the outlier, not a greenfield case.

### Current shape of the data (measured 2026-08-10)

| Metric | Count |
|---|---|
| `work_items` total | 1,105 |
| non-`done` (live) | 388 |
| `done` total | 717 |
| `done` with `review_entered_at` set (passed review) | **80** |
| `done` with `review_entered_at IS NULL` (never reviewed) | **637** |
| `done` with `completed_at IS NULL` | 62 |
| `done` with at least one non-`done` child | 5 |
| `done` and `completed_at` > 30d | 514 |
| `done` and `updated_at` > 30d | 227 |

Two numbers drive the whole design.

**514 vs 227.** `updated_at` is churned by unrelated edits and by trigger writes, so it is **not** a
valid age signal. See §4.2.

**637 of 717 `done` tickets never entered review.** Every one of them is an open
`missing_review` leak in `v_gate_leak_alerts`. This is review debt on *already-shipped* work — it is
not backlog, and archival does not resolve it, only hides it. §5 makes that trade-off explicit
rather than silent.

### Candidate set under the adopted policy (measured 2026-08-10)

| Tier | Rule | Rows |
|---|---|---|
| Reviewed | `review_entered_at IS NOT NULL`, `completed_at` > **14d** | **27** |
| Never reviewed | `review_entered_at IS NULL`, `completed_at` > **60d** | **239** |
| **First-sweep total** | | **266** |
| *Held back* | never reviewed, `completed_at` ≤ 60d — stay visible | *343* |
| *Excluded* | `completed_at IS NULL` | *62* |
| *Excluded* | has a non-`done` child | *5* |

The 27-row reviewed tier is near-noise; in practice this policy is **a 60-day window on unreviewed
work**. Steady state leaves ~839 rows visible, not the ~600 a flat 14-day window would imply,
because new `done` tickets keep landing unreviewed and sit for 60 days. Accepted knowingly: the
board is not the place to fix a review-gate leak.

---

## 2. Decision

**Adopt option (a): a first-class `archived boolean NOT NULL DEFAULT false` column plus
`archived_at timestamptz` on `work_items`. Archived rows keep `status = 'done'`.**

Rejected: (b) a new terminal `status = 'archived'`, and (c) a separate `work_items_archive`
table/partition. Rationale in §3.

Visibility is enforced by **filtering at the read boundary**, matching how `projects.archived`
already works — not by moving or mutating rows.

---

## 3. Options considered

### Option (a) — `archived` flag, `status` stays `done` — **CHOSEN**

- Follows the existing 12-table house convention; zero new vocabulary.
- `status` stays `done`, so **every status-derived metric and join keeps working unchanged**
  (see §4.1 for what breaks under option (b)).
- Reversible by a single `UPDATE ... SET archived = false`.
- Audit trail fully preserved: `completed_at`, `qa_status`, `approval_status`, `review_entered_at`,
  `meta.approval_history` are all untouched.
- Indexable: `archived` is a real column, so PostgREST can filter it and a partial index can serve it.
  A `meta->>'archived'` JSONB flag **cannot** do this well, and — decisively — `kanban_board_view`
  **does not project `meta` at all**, so a JSONB flag would be invisible to the board without a view
  change anyway. If the view has to change either way, take the column.

**Verified against the live trigger stack.** An archival UPDATE leaves `status` unchanged
(`done` → `done`), so every BEFORE UPDATE gate short-circuits:

| Trigger | Behaviour on archival UPDATE |
|---|---|
| `enforce_done_gate` | early-returns (`OLD.status = 'done'`) |
| `enforce_qa_gate` | falls through both branches — `qa_status` preserved |
| `enforce_approval_gate` | not entering `in_progress`/`review` — no-op |
| `enforce_approval_reversal` | `approval_status` unchanged — no-op |
| `enforce_wip_limit` | not entering `in_progress` — no-op |
| `enforce_review_assignee` | not entering `review` — no-op |
| `enforce_authority_governance` | all branches guarded by `status_changed` except the L3+ `approved_by` check — **measured: 0 rows in the `done` pool trip it** |
| `audit_authority_governance` | early-returns on `NEW.status IS NOT DISTINCT FROM old_status` — **0 audit rows emitted** |
| `enforce_epic_linkage` | would re-parent orphan `task`/`chore` rows — **measured: 0 such rows in the `done` pool** |
| `enforce_approval_awaiting_sync` | `approval_status`/`status` unchanged — no-op |
| `audit_approval_reversal` | fires only on approval reversal — no-op |
| `track_review_entry` (`trg_review_sla_tracker`) | keyed on entering `review` — no-op |
| `notify_wip_slot_opened` | keyed on leaving `in_progress` — no-op |
| `generate_ticket_code` | INSERT-only — no-op |
| `trigger_update_updated_at` | **fires — rewrites `updated_at`.** Drives the §4.2 constraint. |

All **15** triggers on `work_items` are listed above; the archival UPDATE is inert for 14 of them.

### Option (b) — new terminal `status = 'archived'` — REJECTED

Rejected on three concrete defects, not on taste:

1. **It silently resurrects blockers.** `kanban_board_view.blocked_by_count` counts blockers via
   `blocker.status <> 'done'`. Flipping an archived blocker off `done` makes it count as blocking
   again — live tickets would spontaneously render as blocked.
2. **It destroys the QA audit trail.** `enforce_qa_gate` opens with
   `IF OLD.status = 'done' AND NEW.status != 'done' THEN NEW.qa_status := NULL`. Archiving 691 rows
   would null `qa_status` on all of them. `move_work_item` likewise nulls `completed_at` on any
   move off `done`.
3. **It corrupts the metrics it is meant to clean.** `jarvis_ops_metrics.done_items` and
   `completion_pct` count `status = 'done'`; `kanban_board_view.completed_child_count` counts
   `child.status = 'done'`. Archiving would crater the completion percentage and regress every epic
   progress bar. The damage is wider than the board: `v_qa_coverage`,
   `v_qa_coverage_authoritative`, `v_gate_leak_alerts` and `vw_audit_health_checks` all key off
   `status = 'done'` as well.

Secondary costs: a CHECK-constraint change, one `governance_audit` row per archived item (691 rows
of `decision = 'auto'` noise, since `audit_authority_governance` fires on status change), and a 9th
column in the PWA bottom-nav (`STATUSES`, `STAT_COLORS`, `STAT_NAMES` at `index.html:501-503`) —
the opposite of de-cluttering the board.

### Option (c) — separate `work_items_archive` table / partition — REJECTED

Highest blast radius, lowest reversibility:

- `work_items.parent_id` is self-referential with `ON DELETE SET NULL`. Moving an archived parent
  out of the table nulls its children's `parent_id`; `enforce_epic_linkage` then silently re-parents
  those children to the project catch-all epic. Hierarchy is lost, not moved.
- `work_item_comments`, `work_item_labels`, `work_item_links`, `test_cases`, and
  `decisions.work_item_id` all reference `work_items.id`. Each needs its own move-or-cascade policy.
- `ticket_code` uniqueness would have to be maintained across two tables.
- Every consumer (**16 dependent views, `kanban_board_view` among them**, plus all three frontends —
  see §4.1) would need a UNION to see history.

Volume does not justify this: 717 `done` rows is not a partitioning problem. Revisit only if
`work_items` passes ~10^6 rows.

---

## 4. Design constraints the build must honour

### 4.1 The filter belongs in the client, **not** in the view

`kanban_board_view` gains `archived` and `archived_at` as projected columns and **keeps no WHERE
clause of its own** (it has none today). The frontend fetches `kanban_board_view?select=*`
(`index.html:546`), so adding columns is backward compatible — the board keeps rendering before the
frontend change lands. The frontend then appends `&archived=eq.false`, exactly mirroring the
existing `projects` call on line 544.

**This is load-bearing, not stylistic.** `kanban_board_view` is the only list query any frontend
makes for work items. Filtering *inside* the view would make the "Archived" chip in §5 physically
unreachable — no PostgREST parameter can recover a row the view has already dropped. The chip works
by toggling the client-side filter off. (Verified via `pg_depend`: no view depends on
`kanban_board_view`, so this choice is contained.)

**Three frontends read `work_items`, not two.** All must be kept in sync:

| File | Board read | Mutations |
|---|---|---|
| `index.html` | `:546` | direct PATCH `:1008` |
| `jarvis-pwa.html` | board fetch | — |
| `jarvis-dashboard.html` | `:460` | PATCH/DELETE `:875`, `:876`, `:884`; `rpc/move_work_item` `:823` |

`jarvis-dashboard.html` is a full third board and was missed in the first draft of this ADR.

**Metrics and audit views must keep counting archived rows** — archival is a display concern, not a
historical one. `jarvis_ops_metrics` is explicitly *not* to be filtered.

A correction to the first draft: it claimed operational views "filter on non-`done` states" and are
therefore unaffected. That is **false**. `v_gate_leak_alerts` is `WHERE status = 'done'`, and every
archival candidate appears in it. The view will keep reporting rows the board can no longer show —
intended, and the reason §5 caps how much unreviewed work may be hidden.

### 4.2 Age is measured from `completed_at`, never `updated_at`

`completed_at` records when the work actually finished. `updated_at` is rewritten by
`trigger_update_updated_at` on *any* write, including trigger-internal `meta` writes and the
archival UPDATE itself. Selecting on `updated_at` would be both wrong now (514 vs 227 rows) and
**non-idempotent**: the first sweep would bump `updated_at` to `now()` on everything it archived,
re-setting the clock on the entire pool.

**No new index.** The existing partial index
`idx_wi_completed ON (user_id, completed_at DESC) WHERE status = 'done'` already serves this
predicate. At 1,105 rows / ~3 MB the planner will seq-scan regardless, and the index proposed in the
first draft was a near-duplicate that served neither the sweep nor the board read (the board reads
all statuses ordered by `sort_order`). Revisit only if the table grows by orders of magnitude.

**Disposition for the 62 `done` rows with `completed_at IS NULL`.** The first draft deferred these
to "manual triage". That is not viable: `governance_audit` only starts 2026-06-12 while these rows
go back to 2026-05-11, so **30 have a reconstructable `done` transition and 32 have none** — 23 of
those 32 are already past any window. Deferral would make them permanently un-archivable and leave
them as a growing residue on the board. The disposition is therefore explicit:

1. Where a `governance_audit` transition into `done` exists (**30 rows**), backfill `completed_at`
   from it. Accurate.
2. Where none exists (**32 rows**), set `completed_at := updated_at` and stamp
   `meta.completed_at_inferred = true`. This is an admitted approximation — `updated_at` is
   *not* a completion time — but it is flagged in the data, reversible, and preferable to a
   permanent blind spot. Rows carrying the flag are still auditable as inferred.

Neither backfill archives anything by itself; it only makes the rows eligible for the normal policy.

### 4.3 Idempotency

The sweep must be safe to run repeatedly. `archived = false` is part of the predicate, so
already-archived rows are excluded and re-runs are no-ops regardless of what the archival write did
to `updated_at`.

### 4.4 Reversibility, and the re-open trap

Un-archiving is `UPDATE work_items SET archived = false, archived_at = NULL WHERE id = $1`. It
crosses no gate and emits no governance audit. This is the single strongest argument for (a) over (c).

**But the deliberate un-archive is not the only way out of `done`.** `move_work_item` sets
`completed_at = NULL` on any move off `done` and never touches `archived`. An archived card dragged
back to `in_progress` would therefore keep `archived = true` — invisible at every read boundary —
*and* lose its `completed_at`, so the sweep could never reach it again. It would be stranded
permanently. `index.html:1008` PATCHes `status` directly, bypassing `move_work_item` entirely, so
fixing the RPC alone is insufficient.

**Required:** a `BEFORE UPDATE` trigger on `work_items` — the only complete fix:

```sql
IF NEW.status <> 'done' AND NEW.archived THEN
  NEW.archived := false;
  NEW.archived_at := NULL;
END IF;
```

Re-opening a ticket un-archives it. Invariant: **`archived = true` implies `status = 'done'`.**

### 4.5 Run identity — without it there is no rollback

"Reversible in principle" is not reversible in practice unless you can name the rows a given run
touched. Today you cannot: `activity_log` has no run identifier (`target_id` holds a single uuid),
and `set_work_item_archived` writes the same `archived_at` field as the sweep, making manual and
swept rows indistinguishable after the fact. `activity_log` also holds **326 rows lifetime** — a
per-row dump of a 266-row candidate set would be ~80% of the table's entire history in one run.

Required:

- Each run generates a `run_id` (uuid) and stamps `meta.archive_run_id` on every row it archives.
- Each run writes **one** summary `activity_log` row: `meta = {run_id, mode, count, ids[]}`.
  One row per run, not per item.
- Rollback is then exactly:
  `UPDATE work_items SET archived = false, archived_at = NULL WHERE meta->>'archive_run_id' = $1`.

Manual archives carry no `archive_run_id`, so a rollback can never catch them.

---

## 5. Archival policy (Process Engineer)

| Question | Decision |
|---|---|
| **Retention window** | **Two tiers.** Reviewed work (`review_entered_at IS NOT NULL`): **14 days**. Never-reviewed work (`review_entered_at IS NULL`): **60 days**. Not a flat 30 — see below. |
| **Archivable** | Any `done` work item meeting its tier's window and not excluded below. |
| **Excluded** | (1) `completed_at IS NULL` until backfilled per §4.2 — 62 today; (2) any row with a non-`done` child — **5 today**. There is **no categorical epic exclusion**: an epic whose children are all `done` is archivable, and the non-`done`-child rule already protects live epics. (The first draft carried both rules inconsistently — ADR text excluded only epics with live children while SB-314 excluded all epics, a 14-row spec conflict. Resolved in favour of the child rule.) No blocker exclusion is needed either: `blocked_by_count` counts a link only when `blocker.status <> 'done'`, so a `done` candidate is by construction not blocking anything. |
| **Trigger** | **Scheduled sweep**, daily, via `pg_cron`. Run at **07:40 UTC**. *Not* 07:30 — `agent-runner-dispatch-cip` is `30 * * * *`, so 07:30 is precisely the collision the first draft claimed to avoid. Manual archive/un-archive stays available from the board. |
| **Authority** | **Split, because L2 does not mean what the first draft assumed.** `authority_levels` row 2 (`recommend`) is `stop_required = true` — "Stop and present decision package… Status `awaiting_jason` until decided." L2 is stop-and-ask *every run*, the opposite of an unattended sweep, and "standing approval" appears nowhere in the governance data. Therefore: **this ADR** is L2 (`process_change` + `new_automation`, both `default_level 2`) and requires Jason's sign-off once. **Each sweep run** is **L0 `routine_maintenance`** ("Pre-authorized recurring upkeep"), which is what actually permits unattended execution. The grant must be recorded on `authority_action_map` the way `pm_coverage_rebalance` records its own ("Approved by Jason 2026-08-02 (GOV-PROP-1, ADR-GOV-002)"). Un-archiving stays L1. |
| **Surfacing** | Board hides archived rows by default via the client-side filter (§4.1). An **"Archived" filter chip** (alongside the status chips at `index.html:919`) toggles the filter off to reveal them read-only. Archived cards render with reduced opacity and an `ARCHIVED` badge. |
| **Restore** | Un-archive from the card's move/edit sheet. No approval required. Re-opening a ticket un-archives it automatically (§4.4). |
| **First run** | **Dry-run first**: write the candidate set to `activity_log`, review the count, then enable. |
| **Anomaly guard** | The sweep **aborts and logs** rather than archiving if the candidate count exceeds 2× the trailing median run (or >50 rows in steady state). Non-negotiable given the environment: `cron.job_run_details` shows **3,831 of 16,656 runs failed (23%)**, and `watch-cip165-dispatch166` has been failing **37%** of its runs unnoticed. A sweep that fails silently is the default outcome here, not the exception. |

### Why two tiers, and why 14 rather than 30

Measured distribution (`completed_at`, 2026-08-10): 7d → 614, 14d → 566, **30d → 496**, 45d → 481,
60d → 235, 90d → 6.

30 vs 45 differs by 15 rows — a distinction without a difference. The real fork is ≤14 vs ≥30, and
at 30 days most project boards still show more `done` cards than live ones. Days 15–30 hold only 70
cards. **14 days** covers a two-week retro and is the better default.

The 60-day tier for never-reviewed work is the deliberate brake. Those 637 rows are open
`missing_review` gate leaks (§1); archiving them on the same 14-day clock would hide 78% of that
backlog within a fortnight. Holding them 60 days keeps recent leaks on the board where they can be
worked, while letting genuinely dead debt clear. **This is a containment measure, not a fix** — the
real remedy is closing whatever lets 637 tickets reach `done` without review, which is out of scope
here and should get its own ticket.

Retention is a policy constant, not a hardcoded literal: store `archive_after_days` and
`archive_after_days_unreviewed` **per project**, with a global default. The first draft put a single
value on the SB project row, but SB is only 194 of 496 candidates (39%) — one project's setting must
not govern the other 18.

---

## 6. Explicitly out of scope

- **No bulk mutation under this ticket.** Per Jason's direction, nothing is archived until this ADR
  is signed off and SB-314 ships.
- No deletion, ever. Archival is a visibility flag; `work_items` rows are never removed by this
  mechanism.
- No change to any CHECK constraint or status vocabulary. One **new** trigger is added (§4.4); no
  existing gate trigger is modified.
- **Fixing the review-gate leak itself.** 637 `done` tickets bypassed review; this ADR contains the
  board-level symptom and deliberately does not address the cause. That needs its own ticket.
- `pt1_dashboard_anon_read` grants anon SELECT on all `work_items` for project
  `ef6fdb53-…`, and `kanban_board_view` is `security_invoker = true`. Any external consumer reading
  through that policy is an unenumerated read path, out of scope here but worth knowing about.

---

## 7. Downstream work

**SB-314 — BUILD: Implement work-item archival (ADR-FLOW-003)**, assigned to Supabase Platform
Engineer, blocked on sign-off of this ADR. Scope:

1. Migration: add `archived boolean NOT NULL DEFAULT false` + `archived_at timestamptz` to
   `work_items`. **No new index** (§4.2). The column add is metadata-only on PG11+ — no table
   rewrite, no lock of consequence at this size.
2. Add the `BEFORE UPDATE` trigger from §4.4 enforcing `archived ⇒ status = 'done'`.
3. Recreate `kanban_board_view` projecting `archived`, `archived_at`, **with no WHERE clause**
   (§4.1). Leave `jarvis_ops_metrics` and all audit views unfiltered.
4. `archive_work_items(p_dry_run boolean DEFAULT true, p_days int DEFAULT 14, p_days_unreviewed int DEFAULT 60)`
   — SECURITY DEFINER, two-tier predicate + §5 exclusions, per-project overrides, `run_id` stamping
   and single summary `activity_log` row (§4.5), anomaly abort (§5), idempotent (§4.3).
5. `set_work_item_archived(p_item_id uuid, p_archived boolean)` RPC for manual archive/restore.
6. `pg_cron` job `work-item-archive-sweep` at `40 7 * * *`, created **disabled**; enabled only after
   the dry-run is reviewed. Add a health check over `cron.job_run_details` for this job.
7. Frontend — **all three boards** (§4.1): `index.html`, `jarvis-pwa.html`, `jarvis-dashboard.html`.
   Append `&archived=eq.false`; add the Archived chip that toggles it; archived card styling;
   restore action. Bump the `sw.js` cache version. (If `jarvis-dashboard.html` is dead, delete it
   under this ticket instead — but do not leave it reading unfiltered.)
8. Backfill the 62 null `completed_at` rows per §4.2: 30 from `governance_audit`, 32 from
   `updated_at` stamped `meta.completed_at_inferred = true`.
9. Record the L0 `routine_maintenance` grant on `authority_action_map` (§5).

**Acceptance criteria** — each must be checkable, and none may reference a stale count:

- [ ] Dry-run count equals a freshly-computed count of the §5 predicate at run time. Do **not**
      hardcode a target number: 266 is a 2026-08-10 measurement, not an invariant.
- [ ] Dry-run returns **zero** rows with a non-`done` child and zero with `completed_at IS NULL`.
- [ ] Two consecutive live runs: the second archives 0 rows.
- [ ] Snapshot `blocked_by_count` per live ticket before and after — unchanged.
- [ ] `jarvis_ops_metrics.done_items` and `completion_pct` unchanged before/after.
- [ ] `governance_audit` row count unchanged (status never changes).
- [ ] `select count(*) from work_items where archived and status <> 'done'` returns **0** after
      moving an archived card to `in_progress` — the §4.4 trigger holds.
- [ ] Archived rows absent from all three boards by default; the Archived chip reveals them.
- [ ] Rollback by `run_id` restores exactly the rows that run archived, and nothing else.
- [ ] `pg_cron` job exists and is **disabled**.

The board still has 9 statuses; the archival work adds no column to the nav.
