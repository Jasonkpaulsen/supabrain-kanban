# PM Triage Dispatch: Step 4a, WIP queue

Source of truth: ADR-FLOW-005 D10 (SB-598). This file is the replacement text for Step 4a
of the `pm-triage-dispatch` SKILL.md on Jason's Mac. Sync it into that SKILL.md; until then
the dispatcher keeps running the old query, which has returned nothing since 2026-08-31.

## Step 4a. WIP queue: tickets parked by the WIP gate

A ticket is parked by the WIP gate when `enforce_wip_limit` redirected it from
`in_progress` to `on_hold`. The gate marks it with the column
`held_by_gate = 'enforce_wip_limit'`. Read the queue from the shared view, never from
`meta`:

```sql
select ticket_code, assignee, priority, blocked_at, queue_age,
       current_wip, wip_limit, slot_available
  from public.v_wip_queue
 order by assignee,
          case priority when 'critical' then 1 when 'high' then 2
                        when 'medium' then 3 when 'low' then 4 else 5 end,
          blocked_at nulls last;
```

Once `supabrain-sweep` is redeployed, the read-only `wip_queue` operation of the
`pm-triage-dispatch` bundle returns the same rows, grouped by assignee with a `ready` list.
Either source is fine; do not write a third query.

`priority` is text, so order it by rank as above, not alphabetically.

### Columns

| Column | Meaning |
|---|---|
| `blocked_at` | When the gate parked the ticket (`meta.wip_blocked_at`). NULL if that value is missing or not a timestamp. |
| `queue_age` | `now() - blocked_at`. |
| `current_wip` | The assignee's in_progress, non-archived tickets for the same owner. |
| `wip_limit` | Resolved exactly as the gate does: `wip_limits.max_wip` for the assignee, else `agents.max_concurrent_tasks`, else 5. |
| `slot_available` | `current_wip < wip_limit`: the ticket can be resumed now. |

### Output

- For each row with `slot_available = true`, print the ticket as
  **`READY — slot available`** (ticket code, assignee, priority, queue age). List these first,
  in the order above: they are the next tickets the assignee should resume.
- Rows with `slot_available = false` are still queued; print them under their assignee with
  `current_wip/wip_limit` and the queue age.
- Report the WIP queue as **clean** only when the view returns **0 rows**.

### Do not

- Do not filter on `meta->>'hold_reason' = 'wip_limit'`. The gate stopped writing that key
  in sb394 (SB-394, 2026-08-31); the filter is dead and always returns 0 rows, which is why
  the queue looked clean for six weeks across 18 WIP blocks and 0 `wip_slot_opened` events.
- Do not use `meta.wip_blocked_assignee`. It is a snapshot from the moment of parking; the
  live `assignee` column is the one that counts.
- Do not treat other `on_hold` tickets as WIP-queued. A prose `meta.hold_reason` (a human
  note on a deliberately held ticket) is not a WIP block.

### Also changed (database, no action needed)

`notify_wip_slot_opened` now uses the same predicate (`on_hold`,
`held_by_gate = 'enforce_wip_limit'`, live assignee), so a `wip_slot_opened` entry in
`activity_log` names the queued tickets again when a slot opens.
