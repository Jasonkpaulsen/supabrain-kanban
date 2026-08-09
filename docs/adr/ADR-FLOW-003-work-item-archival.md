# ADR-FLOW-003 — Work-item archival convention & mechanism

- **Status:** Proposed (awaiting sign-off)
- **Ticket:** SB-313 (DESIGN)
- **Downstream build ticket:** SB-314 (BUILD)
- **Domain:** infrastructure
- **Supersedes / relates to:** ADR-FLOW-001 (WIP limits), ADR-FLOW-002 (review + approval gates on `done`), ADR-COMP-001 (governance audit trail)

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

### Current shape of the data (measured 2026-08-09)

| Metric | Count |
|---|---|
| `done` total | 717 |
| `done` and `updated_at` > 7d | 691 |
| `done` and `completed_at` > 30d | 514 |
| `done` and `updated_at` > 30d | 227 |
| `done` with `completed_at IS NULL` | 62 |
| `done` of type `epic` | 25 |
| `done` with at least one non-`done` child | 5 |

The gap between 514 (`completed_at` > 30d) and 227 (`updated_at` > 30d) is the important number:
`updated_at` is churned by unrelated edits and by trigger writes, so it is **not** a valid age
signal. See §4.3.

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
| `trigger_update_updated_at` | **fires — rewrites `updated_at`.** Drives the §4.3 constraint. |

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
   progress bar.

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
- Every consumer (16 views + `kanban_board_view` + both dashboards) would need a UNION to see history.

Volume does not justify this: 717 `done` rows is not a partitioning problem. Revisit only if
`work_items` passes ~10^6 rows.

---

## 4. Design constraints the build must honour

### 4.1 Read-boundary filtering, not row mutation

`kanban_board_view` gains an `archived` column (and `archived_at`). The frontend fetches
`kanban_board_view?select=*` (`index.html:546`), so **adding columns is backward compatible** — the
board keeps rendering before the frontend change lands. The frontend then appends
`&archived=eq.false`, exactly mirroring the existing `projects` call on line 544.

Operational views (`v_backlog_grooming_queue`, `v_wip_aging_alerts`, `v_orphan_tasks`,
`v_qa_coverage`, …) are unaffected: they filter on non-`done` states. **Metrics views must keep
counting archived rows** — archival is a display concern, not a historical one. `jarvis_ops_metrics`
is therefore explicitly *not* to be filtered.

### 4.2 Age is measured from `completed_at`, never `updated_at`

`completed_at` records when the work actually finished. `updated_at` is rewritten by
`trigger_update_updated_at` on *any* write, including trigger-internal `meta` writes and the
archival UPDATE itself. Selecting on `updated_at` would be both wrong now (514 vs 227 rows) and
**non-idempotent**: the first sweep would bump `updated_at` to `now()` on everything it archived,
re-setting the clock on the entire pool.

The partial index `idx_wi_completed ON (user_id, completed_at DESC) WHERE status = 'done'` already
serves exactly this predicate.

**Fallback for the 62 `done` rows with `completed_at IS NULL`:** do **not** archive them in the
first pass. Backfill `completed_at` from the most recent `governance_audit` transition into `done`
where one exists, and leave the remainder for manual triage. Guessing a completion date to make a
row disappear is how audit trails rot.

### 4.3 Idempotency

The sweep must be safe to run repeatedly:
`WHERE status = 'done' AND archived = false AND completed_at < now() - interval '<N> days'`.
Already-archived rows are excluded by `archived = false`, so re-runs are no-ops regardless of what
the archival write did to `updated_at`.

### 4.4 Reversibility

Un-archiving is `UPDATE work_items SET archived = false, archived_at = NULL WHERE id = $1`. It
crosses no gate and emits no governance audit. This is the single strongest argument for (a) over (c).

---

## 5. Archival policy (Process Engineer)

| Question | Decision |
|---|---|
| **Retention window** | `status = 'done'` **and** `completed_at` older than **30 days**. Not 7 — 7 days is inside the window where a closed ticket is still routinely referenced in review and retro. 30 days archives **514** rows today and leaves a working recent-history tail. |
| **Archivable** | Any `done` work item meeting the window and not excluded below. |
| **Excluded** | (1) rows with `completed_at IS NULL` — 62 today, see §4.2; (2) `type = 'epic'` with at least one non-`done` child — archiving a live epic's container hides active work; (3) any row with a non-`done` child — **5 today**; (4) rows referenced as an unresolved blocker in `work_item_links` where the blocked item is not `done`. |
| **Trigger** | **Scheduled sweep**, daily, via `pg_cron` — consistent with the five existing jobs in `cron.job`. Run at **07:30 UTC**, after `lce-daily-cleanup` (07:00) and clear of `agent-runner-dispatch-cip` (:30 hourly). Manual archive/un-archive of a single ticket stays available from the board. |
| **Authority** | The sweep is **L2, `action_category = 'process_change'`** — reversible, non-destructive, no user data. It runs under standing approval once this ADR is signed off. Un-archiving is L1. |
| **Surfacing** | Board hides archived rows by default. An **"Archived" filter chip** (alongside the existing status chips at `index.html:919`) reveals them read-only. Archived cards render with reduced opacity and an `ARCHIVED` badge so they are never mistaken for live work. |
| **Restore** | Un-archive from the card's move/edit sheet. No approval required. |
| **First run** | The initial sweep is **dry-run first**: log the candidate set to `activity_log`, have the Process Engineer eyeball the count, then enable. |

Retention is a policy constant, not a hardcoded literal: store `archive_after_days` in
`meta` on the SB project row so it can be tuned without a migration.

---

## 6. Explicitly out of scope

- **No bulk mutation of the 691 rows under this ticket.** Per Jason's direction, nothing is archived
  until this ADR is signed off and SB-314 ships.
- No deletion, ever. Archival is a visibility flag; `work_items` rows are never removed by this
  mechanism.
- No change to any gate trigger, CHECK constraint, or status vocabulary.

---

## 7. Downstream work

**SB-314 — BUILD: Implement work-item archival (ADR-FLOW-003)**, assigned to Supabase Platform
Engineer, blocked on sign-off of this ADR. Scope:

1. Migration: add `archived boolean NOT NULL DEFAULT false` + `archived_at timestamptz` to
   `work_items`; partial index `ON (user_id, completed_at DESC) WHERE status = 'done' AND archived = false`.
2. Extend `kanban_board_view` with `archived`, `archived_at`. Leave `jarvis_ops_metrics` alone (§4.1).
3. `archive_work_items(p_dry_run boolean DEFAULT true, p_days int DEFAULT 30)` — SECURITY DEFINER,
   applying §5 exclusions, logging the candidate set to `activity_log`, idempotent per §4.3.
4. `set_work_item_archived(p_item_id uuid, p_archived boolean)` RPC for manual archive/restore.
5. `pg_cron` job `work-item-archive-sweep` at `30 7 * * *`, created **disabled**; enabled only after
   the dry-run is reviewed.
6. Frontend (`index.html` + `jarvis-pwa.html`, kept in sync): append `&archived=eq.false`; add the
   Archived filter chip; archived card styling; restore action. Bump the `sw.js` cache version.
7. Backfill `completed_at` from `governance_audit` for the 62 null rows where a `done` transition
   exists; report the remainder.

**Acceptance:** dry-run returns exactly the expected candidate set; a live run archives it and a
second immediate run archives 0 more (idempotency); `jarvis_ops_metrics.completion_pct` and every
epic's `completed_child_count` are unchanged before/after; `blocked_by_count` is unchanged;
`governance_audit` gains 0 rows; un-archiving one ticket returns it to the board.
