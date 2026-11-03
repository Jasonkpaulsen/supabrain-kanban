# Management Agent Sweep: handoff-gap check

Source of truth: ADR-FLOW-005 D9 (SB-558). This file is the rule text for the
`management-agent-sweep` skill on Jason's Mac. It replaces the sweep's self-written
"Architect tickets with no linked Platform Engineer ticket" query. Sync it into that
SKILL.md; until then the sweep keeps using the old rule.

## 1. Call the detector, do not re-derive it

```sql
select * from public.detect_handoff_gaps();          -- System Architect, last 14 days, design work only
-- full population, for the role-boundary report:
select * from public.detect_handoff_gaps('System Architect', 14, false);
```

Do not write your own `where assignee = 'System Architect'` query. Exactly one
`detect_handoff_gaps` exists; the two old overloads are retired
(`detect_handoff_gaps_retired_sb558_v1/_v2`) and not callable by client roles.

## 2. What each finding_type means and what to do

| finding_type | Meaning | Action |
|---|---|---|
| `handoff_gap` | Design work by the upstream role, not tested, no downstream link. | **Escalate.** Verify first (step 4). This is the only type that escalates. |
| `role_boundary` | The upstream role built and tested non-design work itself. | Group all rows into **one** role-boundary report per sweep. Never call it a handoff gap. Jason decided in SB-527 (2026-10-07) that the handoff is enforced. |
| `reviewed_only` | Built by another role; the upstream role only reviewed it. | Informational. |
| `linked` | Has a `blocks` / `blocked_by` handoff link. | Informational. |
| `legacy_meta_backfill` | Linked only through a legacy meta key (`upstream_ticket` on a downstream, or `downstream_ticket`). | Informational; a `work_item_links` backfill may be filed. |
| `design_complete` | Design work built and tested by the upstream role. | Informational. |
| `shipped_exempt` | Shipped with `qa_status = exempt`. | Informational. |
| `self_contained` | No handoff expected. | Informational. |

## 3. Why these rules

- **The developer is `meta.developed_by`, not the assignee.** Review entry
  (`enforce_review_assignee`) reassigns a ticket to its reviewer, so a done ticket's
  `assignee` is often the reviewer. The detector uses
  `coalesce(meta.developed_by, assignee)`. Counting by assignee is what made SB-557 report
  7 Platform Engineer CRM tickets as unimplemented Architect work, and what made SB-527
  read a 3.4x inversion that is not there.
- **Only `blocks` and `blocked_by` are handoff links.** `relates_to` and `duplicates`
  do not hand anything off.
- **`qa_status` is evidence of shipped work.** `tested` or `exempt` means it was built.

## 4. Before escalating a handoff_gap

- Never infer "not implemented" from a missing ticket. Check `qa_status`, test cases and
  the deployed objects (tables, functions, edge functions) the ticket names.
- If the work shipped, the row is mis-tagged: comment on it, do not escalate.
- One consolidated escalation per sweep, listing ticket codes. Do not file per-day
  duplicates; append to the open one.
