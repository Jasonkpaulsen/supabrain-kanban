# ADR-FLOW-004: Ticket cancellation as a terminal state

- **Status:** Accepted (Jason, 2026-10-10)
- **Tickets:** SB-560 (epic), SB-561 (mechanism, System Architect), SB-562 (policy, SupaBrain Process Engineer), SB-563 (build), SB-564 to SB-566 (UI spec, UI build, QA)
- **Related:** ADR-FLOW-003 (work item archival), GOV-001 (`enforce_authority_governance`)

## 1. Problem

`work_items.status` has no cancelled state. Retiring a ticket means `status = 'done'`, which counts it as delivered in every completion metric. A ticket Jason rejected cannot be closed honestly: `enforce_done_gate` refuses `approval_status = 'rejected'` → `done` unless `meta.approval_gate_exempt` bypasses the gate. Jason hit this on 2026-10-07 with LCE-041 and LCE-070. 36 tickets were closed as `done` with an ad hoc `meta.closure_reason` such as `superseded`, `duplicate` or `redundant_with_dashboard_review_queue`.

## 2. Decisions (Jason, 2026-10-10)

| # | Question | Decision |
|---|----------|----------|
| D1 | Mechanism | A new terminal status `cancelled`, not `done` + a reason. |
| D2 | Who may cancel | By the ticket's authority level (§4). |
| D3 | Reasons | Five codes; a replacing ticket is required for two, a note for three (§5). |
| D4 | History | Convert the 36 clear `closure_reason` rows; leave "fixed: delivered under …" as done (§8). |

## 3. Mechanism (System Architect)

**Status.** `cancelled` joins `work_items_status_check`. It is terminal: the only ways out are a reopen (§6) or archival.

**Columns** on `work_items`, all NULL unless `status = 'cancelled'`:

| Column | Meaning |
|--------|---------|
| `cancel_reason` | One of the five codes in §5 (CHECK). |
| `cancel_note` | Free text; required by three codes. |
| `cancel_replaced_by` | The ticket that replaces this one (FK, `ON DELETE SET NULL`). |
| `cancelled_at` | Stamped by the trigger. |
| `cancelled_by` | The actor, written by the caller (same trust model as `approved_by`). |

`work_items_cancel_fields_check` holds the invariant: either `status = 'cancelled'` with reason, actor and time set, or none of the five columns set.

**New trigger `trg_cancellation`** (`enforce_cancellation()`, BEFORE INSERT OR UPDATE). It sorts before `trg_enforce_authority_governance`, so GOV-001 sees the row it produces.
- **INSERT as cancelled:** refused; create the ticket, then cancel it.
- **Into cancelled:**
  - validates reason, note and replacement (§5) and authority (§4);
  - refuses a parent that still has open children;
  - stamps `cancelled_at`;
  - when Jason cancels a ticket from `awaiting_jason`, sets `approval_status = 'rejected'` and `approved_by = 'Jason'`, which is exactly what GOV-001 requires to leave `awaiting_jason`.
- **While cancelled:** the five fields are locked; reopen and re-cancel to change them.
- **Out of cancelled (reopen):** §6.
- **Outside cancellation:** setting cancel fields on a non-cancelled row is refused with a clear error. The CHECK is only the backstop.

**Existing triggers.** A cancellation passes every gate without exemptions:

| Trigger | Effect on a cancellation |
|---------|--------------------------|
| `enforce_done_gate` | Fires only into `done`; not reached. |
| `enforce_qa_gate` | Fires only into `done`. Moving `done` → `cancelled` (backfill) clears `qa_status`, as any exit from `done` does. |
| `maintain_completed_at` | Never stamps a cancellation; `done` → `cancelled` clears `completed_at`. |
| `enforce_approval_gate`, `enforce_wip_limit`, `enforce_review_wip_limit` | Fire only into active states; not reached. |
| `enforce_authority_governance` | Unchanged. Its L2+ close rule names `done`, and exiting `awaiting_jason` still needs Jason, which `trg_cancellation` provides when the actor is Jason. |
| `track_review_entry`, `clear_hold_marker_on_unhold`, `notify_wip_slot_opened` | Unchanged; leaving `review`, `on_hold` or `in_progress` for `cancelled` behaves like any exit. |
| `enforce_archived_implies_done` | **Changed:** `cancelled` rows may be archived too. |
| `audit_authority_governance` | **Changed:** every cancellation and reopen writes a `governance_audit` row, whatever the authority level (decisions `cancelled`, `reopened`, added to the CHECK). |

**Reads that treat "not done" as "open"** are changed to treat `cancelled` as closed. Reads that count `status = 'done'` as delivered already exclude it.

| Object | Change |
|--------|--------|
| `jarvis_ops_metrics` | `total_items` and `completion_pct` exclude cancelled. Stale, overdue and unassigned counts exclude it. New trailing column `cancelled_items`. |
| `kanban_board_view` | `child_count` excludes cancelled children; a cancelled blocker no longer counts in `blocked_by_count`. New trailing columns for the five cancel fields (for SB-565). |
| `generate_daily_audit` | Every "open" filter excludes cancelled; `flow_metrics` gains a `cancelled` count. |
| `archive_work_items` | Archives cancelled rows by `cancelled_at` with the same retention as done rows. A cancelled child no longer blocks archiving its parent. |
| `crm_steward_scheduled` | Its de-duplication check for an open failure ticket ignores cancelled tickets. |
| `sync_school_assignment_to_fam` | Never moves a cancelled FAM reminder to `done`, and never revives it. A parent's cancellation stands. |

Unchanged on review:
- `v_empty_epics` already excluded `cancelled`.
- `supabrain-sweep` and `agent-runner` select explicit open statuses.
- `v_qa_coverage*`, `v_gate_leak_alerts`, `vw_audit_health_checks`, `vw_approval_compliance`, `detect_handoff_gaps` and `track_review_entry` are about `done` only.
- `move_work_item` cannot cancel, because it carries no reason, so the trigger refuses. The board uses the RPC below instead.

**RPCs** (SECURITY INVOKER, `search_path` pinned, closed to anon; owner check as in `move_work_item`):
- `cancel_work_item(p_item_id uuid, p_reason text, p_note text, p_replaced_by text, p_actor text) returns jsonb`. `p_replaced_by` is a ticket code.
- `reopen_work_item(p_item_id uuid, p_status text default 'backlog') returns jsonb`

**Briefing feed.** `v_recent_cancellations` (security invoker) lists the last 7 days' cancellations with level, reason, actor and whether Jason must be told (L2 by someone other than Jason). JARVIS's briefing reads it for the "Retired" line; cancelled items never count as accomplishments.

## 4. Authority (Process Engineer, D2)

The level is the ticket's `authority_level`; NULL counts as L1.

| Level / state | Who may cancel |
|---------------|----------------|
| L0–L1 | Any agent or PM, with a reason. |
| L2 | A PM, JARVIS, or Jason, with a reason. Jason is told through `v_recent_cancellations`. |
| L3–L4, or the ticket is in `awaiting_jason` | Only Jason. |
| reason `rejected_by_jason` | Only Jason, at any level. |

"PM" means an actor whose name matches `PM` as a word or contains `Project Manager`: SupaBrain Operations PM, Family PM, CIP Project Manager, and so on. Domain specialists such as Family Care Manager or 39P Operations Manager are not PMs; they ask their PM. `cancelled_by` is written by the caller and is not verified, the same trust model as `approved_by` under GOV-001. Every cancellation is audited, so misuse is visible.

Cancellation is listed in `authority_action_map` as `ticket_cancellation` (default level 1; the effective level is the ticket's). `meta.approval_gate_exempt` must no longer be used to retire a ticket. A rejected ticket is cancelled with `rejected_by_jason`.

## 5. Reason codes (D3)

| Code | Requires |
|------|----------|
| `duplicate` | `cancel_replaced_by`: the ticket it duplicates (not itself). |
| `superseded` | `cancel_replaced_by`: the ticket that replaces it (not itself). |
| `no_longer_relevant` | `cancel_note` (3+ characters). |
| `wont_do` | `cancel_note`. |
| `rejected_by_jason` | `cancel_note`; actor Jason. |

## 6. Reopen

A cancelled ticket can be reopened to `backlog`, `todo` or `awaiting_jason`, never straight to an active state or `done`. An L3–L4 ticket, or one cancelled as `rejected_by_jason`, reopens only to `awaiting_jason`, so Jason decides again. A reopen moves the five fields into `meta.cancel_history` (an array) and writes a `reopened` audit row. Moving onward from there passes every normal gate.

## 7. Parents

An epic or parent with open children cannot be cancelled. Cancel or close the children first. Nothing cascades silently.

## 8. Backfill (D4)

The 36 `done` rows whose `meta.closure_reason` describes a non-delivery become `cancelled`, with `cancelled_by = 'Jason'` (his decision of 2026-10-10) and `cancelled_at` = their old `completed_at`:
- `duplicate` with `meta.duplicate_of` → `duplicate`, pointing at that ticket.
- `superseded` with `meta.superseded_by`, and `consolidated_into_…` → `superseded`, pointing at the first named ticket. The note keeps the full original text.
- every other non-delivery reason → `no_longer_relevant`, with the original text as the note.

The two "fixed: delivered under …" rows stay `done`.

## 9. Consequences

- **Metrics:** completion figures drop slightly and become honest. The backfill removes 36 items from "done".
- **Boards:** the web boards and the PWA do not render a `cancelled` column until SB-565. Until then cancelled items are simply absent from the board, which is the intended end state for retired work anyway.
- **Rollback:** reopen the rows, then revert the migration. The CHECK and columns can be dropped once no row is `cancelled`.
