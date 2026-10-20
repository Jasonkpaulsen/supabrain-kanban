# ADR-FLOW-005: Sweep signal quality

- **Status:** Accepted (System Architect, 2026-10-14) for the additive, read-side parts. The two enforcement switches in D7 and D8 stay **Proposed** until Jason approves SB-554 and SB-526.
- **Tickets:** SB-593 (external-wait state), SB-550 (cancelled as a duplicate of SB-593), SB-554 (Jason decision digest), SB-526 (escalation closure), SB-558 (handoff-gap detector), SB-598 (WIP-queue signal)
- **Related:** ADR-FLOW-004 (ticket cancellation), GOV-001 (`enforce_authority_governance`), SB-394 (hold columns), SB-376 (handoff detector), SB-563 (in-place function patch), SB-567 (long UPDATE payloads)

## 1. Problem

Every sweep, metric view and escalation rule decides whether a ticket is healthy from `status`, `due_date`, `updated_at` and the current `assignee`. None of them can see **who or what the ticket is waiting on**. Five tickets describe the same blind spot from different angles:

| Ticket | What the sweep cannot see | Symptom (2026-10-14) |
|--------|---------------------------|----------------------|
| SB-593 / SB-550 | An outside party has the next move. | 39P-026 pushed to Jason as "due today and unmoved" while NYC Parks had a 30-day window. `stale_wip_gt3d` = 30 includes it. Review dwell grows +24h/day (216 → 312h, 10-09 to 10-13). |
| SB-554 | Jason is the blocker. | 4 of 19 `awaiting_jason` items are escalations of items already waiting on Jason; 3 of the 4 critical items are escalations. |
| SB-526 | The blocker an escalation names. | 6 of 12 done escalations have an upstream still not finished; 4 were closed as `done` with exempt flags. |
| SB-558 | Who built the ticket (the reviewer is reassigned at review entry). | 20 false "candidate gap" rows; the 7 CRM tickets in SB-557 were built by Platform Engineer and only reviewed by the Architect. `detect_handoff_gaps('System Architect',14)` fails with 42725. |
| SB-598 | The gate that parked the ticket. | `notify_wip_slot_opened` filters on `meta.hold_reason = 'wip_limit'`, which nothing has written since SB-394 (2026-08-31): 18 blocks, 0 slot-opened events. |

The rules that create the pushes and escalations (JARVIS briefing, management-agent-sweep, pm-triage-dispatch) run as scheduled tasks on Jason's Mac. Their SKILL.md files are not in the database or this repo.

## 2. Principle

Each "waiting on X" fact gets **one field**, written by the actor that knows it, and **one read-side object** (view or function) in the database that every sweep shares. Sweeps read that object. They do not re-derive the rule from status and dates. Mac-resident rules are written in `docs/skills/` and synced to the device by Jason.

## 3. Decisions

| # | Ticket | Decision |
|---|--------|----------|
| D1 | SB-593 | **External-wait contract.** Four `work_items` meta keys are registered in `meta_key_registry` (owner System Architect): `awaiting_external` (text naming the party; present, non-empty and not `'false'` means waiting), `external_ref` (optional, e.g. an SR number), `external_since` (YYYY-MM-DD, our action complete), `external_clock_expires` (YYYY-MM-DD, their window lapses = our follow-up date, which is SB-550's `follow_up_at`). `due_date` always means **our** next action; while waiting it is the follow-up date. `inspect_by`, `resolve_by`, `sweep_treatment`, `our_action_complete` are legacy and unread. `meta.blocked_on` keeps its meaning (a person or step) and is not reused. |
| D2 | SB-593 | **One classifier.** `external_wait_clock(meta, due_date)` = valid `external_clock_expires`, else `due_date`; a malformed date yields NULL, never an error. `work_item_wait_state(meta, due_date, today)` returns NULL (not waiting), `waiting_on_track` (today ≤ clock), `external_clock_expired` (today > clock) or `waiting_no_clock`. It ignores status, so a wait may sit in any status. A boolean-like value (`true`, `yes`) counts as waiting with party NULL. `v_external_wait_status` (security invoker) lists open waits with party, clock, clock source and severity `info` / `escalate` / `data_quality`. |
| D3 | SB-593 | **Exclusions.** `vw_audit_health_checks.stale_wip_gt3d` and `jarvis_ops_metrics` stale/overdue/blocked counts exclude `waiting_on_track` and `waiting_no_clock`; expired clocks stay counted. `jarvis_ops_metrics` appends `external_wait_on_track` and `external_clock_expired`. `v_review_dwell_alerts`, `v_review_sla_breaches` and `review_sla_sweep()` skip every waiting item; an expired wait surfaces once, as `severity = 'escalate'` in `v_external_wait_status` (SB-550's higher-severity flag). In the `supabrain-sweep` edge function, `stale_wip` and `blocked_items` skip any wait and the new `external_waits` operation returns the on-track / expired / no-clock lists. Views keep their columns and order; new columns are appended. |
| D4 | SB-593 | **Status convention (recommended, not enforced).** A wait may be parked in `on_hold` with `hold_reason = 'awaiting external: <party>'`, which frees the WIP slot. No ticket is moved by this ADR. |
| D5 | SB-550 | **Cancelled as a duplicate of SB-593** (`cancel_work_item`, reason `duplicate`, replaced by SB-593) with a `duplicates` link. SB-593 covers all four asks: the wait state (D1), the follow-up date (D1), the review-dwell exclusion and expired flag (D3). The 39P-018 backfill needs a party and clock only Jason knows, so it is a morning item. |
| D6 | SB-554 | **Jason-blocker class.** `escalation_subject_codes(meta)` reads `blocker_ref`, `upstream_ticket`, `related_tickets[]`, `requires_jason[]`. `jason_blocker_class(codes)` returns `human_decision` (a subject is `awaiting_jason`, a pending L2+ or proposal approval, or `requires_jason`/`needs_jason` true, or is blocked by such an item one hop up), `agent`, or `unresolved`. A BEFORE INSERT trigger stamps `meta.blocker_class`, `digest_routed` and `classified_by` on ESCALATION rows and never blocks an insert. An L3+, `flagged_for_jason` or `awaiting_jason` escalation is `human_decision` regardless of subject. |
| D7 | SB-554 | **One decision digest.** `vw_jason_decision_digest` and `jason_decision_digest()` list each open item waiting on Jason once, with `waiting_days`, aging thresholds (critical 3, high 7, medium 14, low 30 days) and the no-op escalations folded into `escalations_attached`. Items waiting on an outside party (D1) are not Jason decisions. **Proposed:** refusing a `human_decision` escalation at insert. It is built behind `escalation_gate_mode('SB-554')`, which returns `warn` until Jason approves SB-554. |
| D8 | SB-526 | **Escalation closure follows the upstream.** `escalation_upstream_id` resolves the escalated ticket (meta `upstream_ticket`, then `escalates`, then the first ticket code in the title); `handoff*` issue types and unresolvable upstreams are out of scope. On insert the trigger stamps `meta.escalation_snapshot` (upstream status, assignee, open blockers). Closing into `done` while the upstream is still stuck is ESCALATION-002 when nothing changed since the snapshot, and ESCALATION-001 when there is no re-verification evidence (a comment on the upstream after the escalation, an owned upstream, every open blocker owned). `vw_escalation_closure_audit` reports `ok`, `held`, `violation` and `governance_violation` (upstream blocked > 14 days with a done escalation in its history). No `*_exempt` flag is honoured; the escape hatch is `cancel_work_item` with `duplicate`. **Proposed:** raising on a held close. Until Jason approves SB-526, `escalation_gate_mode('SB-526')` returns `warn`: the close succeeds, the verdict is stamped in `meta.escalation_closure` and a WARNING is raised. |
| D9 | SB-558 | **Handoff findings by developer, not reviewer.** The developer is `coalesce(meta.developed_by, assignee)`. Only `blocks` (from the ticket) or `blocked_by` (into it) counts as a handoff link; `relates_to` and `duplicates` do not. `classify_handoff_finding` returns `reviewed_only`, `linked`, `legacy_meta_backfill`, `design_complete`, `role_boundary`, `shipped_exempt`, `handoff_gap` or `self_contained`. Sweeps escalate only `handoff_gap`; `role_boundary` is reported as a role-boundary finding. The two old overloads are renamed `detect_handoff_gaps_retired_sb558_v1/_v2` and closed to client roles, so exactly one `detect_handoff_gaps` exists and short calls resolve. |
| D10 | SB-598 | **The WIP queue reads the column the gate writes.** A parked ticket is `status = 'on_hold' and held_by_gate = 'enforce_wip_limit'`. `v_wip_queue` (security invoker) is the one query both consumers share; it resolves the limit as `enforce_wip_limit` does (`wip_limits.max_wip`, then `agents.max_concurrent_tasks`, then 5). `notify_wip_slot_opened` uses that predicate and the live `assignee`, not the stale `meta.wip_blocked_assignee`. The meta write is not restored. |
| D11 | all | **Mac-resident rules ship as docs; the edge function gains read-only operations.** `supabrain-sweep` adds `external_waits`, `decision_digest` and `wip_queue` (all `mutates: false`) to the `pm-triage-dispatch` bundle, and `decision_digest` to `management-agent-sweep`. Rule text for the Mac lives in `docs/skills/`. Deploy and device sync are Jason's morning items. |

## 4. Objects changed

| Package | Tickets | Database | Repo |
|---------|---------|----------|------|
| pkg-1 | SB-593 (SB-550) | `meta_key_registry` (4 rows), new `external_wait_clock`, `work_item_wait_state`, `v_external_wait_status`; replaced `vw_audit_health_checks`, `jarvis_ops_metrics`, `v_review_dwell_alerts`, `v_review_sla_breaches`, `review_sla_sweep()` | migration `sb593_external_wait_state`, `supabase/tests/external_wait_state_suite.sql`, `supabase/functions/supabrain-sweep/*`, `docs/skills/jarvis-briefing-external-wait.md` |
| pkg-2 | SB-554, SB-526 | new `escalation_gate_mode`, `escalation_subject_codes`, `jason_blocker_class`, `classify_escalation_on_insert` + `trg_escalation_blocker_class`, `vw_jason_decision_digest`, `jason_decision_digest()`, `escalation_upstream_id`, `escalation_open_blockers`, `enforce_escalation_closure` + `trg_escalation_closure`, `vw_escalation_closure_audit` | migrations `sb554_jason_decision_digest`, `sb526_escalation_closure_gate`; suites `jason_decision_digest_suite.sql`, `escalation_closure_gate_suite.sql`; `docs/skills/management-agent-sweep/escalation-rules.md` |
| pkg-3 | SB-558 | `detect_handoff_gaps` (2 overloads renamed and revoked, 1 new), new `classify_handoff_finding` | migration `sb558_handoff_detector_reads_developer_and_qa`, `supabase/tests/handoff_gap_detector_suite.sql`, `docs/skills/management-agent-sweep/handoff-gap-check.md` |
| pkg-4 | SB-598 | `notify_wip_slot_opened()`, new `v_wip_queue` | migration `sb598_wip_queue_reads_held_by_gate`, `supabase/tests/wip_queue_monitoring_suite.sql`, `docs/skills/pm-triage-dispatch/STEP-4A-wip-queue.md` |

No ticket data is rewritten by any migration. No database object or file belongs to two packages.

## 5. Out of scope

- `generate_daily_audit` (legacy; no longer writes the daily audits). Its body cannot be resent through `CREATE OR REPLACE` under tonight's rules, so it is left unchanged.
- Backfilling wait keys on 39P-026, 39P-018, 39P-017, 39P-013 and FAM-051. The parties and clocks are Jason's to confirm; 39P-026 already classifies correctly through `due_date`.
- WW-012 / WW-013: they wait on Jason, not an outside party, so they belong to the decision digest (D7) and are not tagged `awaiting_external`.
- Moving SB-520, SB-549, SB-553, 39P-027 or SB-413 out of `awaiting_jason` (GOV-001: only Jason).
- The blocked > 72h and awaiting_jason > 7d SLA (SB-526 item 2). It should share one mechanism with SB-450/451; D7's aging thresholds are the read-side half.
- A `status_entered_at` column. Ages are measured from `updated_at`, which under-reports.
- Permanently removing the two retired `detect_handoff_gaps` overloads, and a shared `wip_limit_for()` helper (SB-388).
- The title-prefix chain inference in the 10-10 brief ("Ticket D"); filed separately.

## 6. Consequences

- **Metrics:** stale and overdue counts drop by the number of live waits (30 → 29 for `stale_wip_gt3d` today) and rise again when a clock lapses.
- **Until the Mac skills are updated,** JARVIS and the sweeps keep computing their own rules. The database objects are correct immediately but change no push until the device sync.
- **Enforcement:** flipping D7 or D8 to `enforce` is one `CREATE OR REPLACE` of `escalation_gate_mode`, applied only after Jason approves the ticket.
- **Rollback:** every change is a new object or a `CREATE OR REPLACE` of an existing one; reverting means re-applying the previous definition (kept in `supabase_migrations.schema_migrations`). The renamed handoff overloads can be renamed back.

## 7. Amendment 1 (System Architect, 2026-10-20): SB-601, SB-602, SB-603, SB-604

The SB-593 verifier left four low-priority gaps that D2, D3 and the pkg-1 build did not
cover. None changes which items count as waiting; three change how the result is read.

| # | Ticket | Decision |
|---|--------|----------|
| D2a | SB-603 | **A present-but-invalid tag is a data-quality finding, not a silent fallback.** `work_item_wait_state` and `external_wait_clock` are unchanged, so D3's exclusions do not move. A new `external_wait_data_quality(meta, due_date)` returns NULL or one issue, in this order: `invalid_clock` (`external_clock_expires` is present and non-blank but not a valid `YYYY-MM-DD`), `non_text_party` (`awaiting_external` is a JSON object or array; a JSON boolean is boolean-like under D2 and is fine), `no_clock` (no valid clock and no `due_date`). `v_external_wait_status` appends `data_quality_issue`; reports `clock_source = 'due_date_fallback'` when an invalid meta clock fell back to `due_date`; returns `external_party` NULL for a non-text party; and sets `severity` to `escalate` when the clock has lapsed, else `data_quality` when an issue is present, else `info`. A lapsed clock outranks a data-quality issue because it is our move either way; the issue stays visible in `data_quality_issue`. Validating the keys on write is out of scope. |
| D3a | SB-601, SB-602 | **The edge reads the database classification; it no longer re-derives it.** `v_open_work_wait_state` (security invoker; SELECT for `service_role` only) lists open, unarchived work items with the columns the edge returns plus `wait_state = work_item_wait_state(meta, due_date)`. In `supabrain-sweep`, `stale_wip`, `blocked_items` and now `review_queue_aging` read it and keep `wait_state is null`. `NOT_WAITING_FILTER` and `edgeTreatsAsWaiting` are removed, so whitespace and case are judged by the same classifier as every other sweep. `review_queue_aging` closes the D3 gap on the edge path (SB-601). `external_waits` also returns `severity` and `data_quality_issue` and counts `data_quality`. |
| D12 | SB-604 | **SECURITY DEFINER functions on the review path pin `search_path = ''`.** `review_sla_sweep()` and `get_review_alerts(numeric, text)` are re-sent with every relation schema-qualified and no other change. Grants are unchanged (postgres, service_role). The `work_item_wait_state(meta, due_date) IS NULL` anchor that TC-SB593-7 pins is kept verbatim. |

Objects: migration `sb601_604_wait_state_reads_and_review_search_path`; suites
`supabase/tests/external_wait_state_suite.sql` (TC-SB593-7 now pins 17 columns on
`v_external_wait_status`) and `supabase/tests/wait_state_followups_suite.sql`;
`supabase/functions/supabrain-sweep/{index.ts,ops.ts,ops.test.ts,README.md}`;
`docs/skills/jarvis-briefing-external-wait.md`. Rollback: re-apply the previous
definitions from `supabase_migrations.schema_migrations` and redeploy `supabrain-sweep` v5
(commit cb2575e).
