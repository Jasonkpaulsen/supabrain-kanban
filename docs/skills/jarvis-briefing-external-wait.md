# JARVIS briefing: external-wait rule (SB-593)

Source: ADR-FLOW-005 D1-D4 (`docs/adr/ADR-FLOW-005-sweep-signal-quality.md`), migration
`supabase/migrations/20261014111002_sb593_external_wait_state.sql`.

**Install:** paste the rule block below into the JARVIS briefing `SKILL.md` on Jason's Mac,
before the stale / overdue / notification steps. That file is not in this repo, so the
database change does nothing to the briefing until this block is on the device.

---

## Rule block (copy from here)

### External waits: read the view, do not re-derive

Some tickets are waiting on an outside party (a city agency, an insurer, a vendor). Our
action is done and their window is running. They are not neglected, and they must not be
reported as stale or overdue while that window is open.

1. **Read `public.v_external_wait_status`** once per briefing:

   ```sql
   select ticket_code, status, assignee, priority, external_party, external_ref,
          external_since, clock_expires, clock_source, days_to_clock, wait_state, severity
     from public.v_external_wait_status
    order by days_to_clock nulls last;
   ```

   Use this view to decide whether a ticket is waiting. Do not work it out from `status`,
   `due_date`, `updated_at`, the title or the legacy keys `inspect_by`, `resolve_by`,
   `sweep_treatment` and `our_action_complete`. The database does not read those keys.

2. **`wait_state = 'waiting_on_track'` (severity `info`)**: put these in an informational
   section titled **"Waiting, on track"**, one line each:
   `<ticket_code>: waiting on <external_party>, follow up <clock_expires> (<days_to_clock> days)`.
   When `external_party` is NULL (the tag was a bare `true`), write "an outside party".
   These items are **never** counted in `stale_in_progress`, `overdue` or
   `notification_sent`, never appear in the action-required section and never trigger a
   push. `jarvis_ops_metrics.stale_items`, `overdue_items` and `blocked_items` already leave
   them out. Report `external_wait_on_track` as its own number.

3. **`wait_state = 'external_clock_expired'` (severity `escalate`)**: the party's window has
   lapsed and it is our move. This **is push-worthy**. Put it in the action-required section,
   ranked above an ordinary overdue item of the same priority:
   `<ticket_code>: <external_party> window lapsed <clock_expires> (<-days_to_clock> days ago), follow up or escalate`.
   These items stay in the stale / overdue counts. `jarvis_ops_metrics.external_clock_expired`
   counts them.

4. **`wait_state = 'waiting_no_clock'` (severity `data_quality`)**: the item is tagged as
   waiting but has no valid `external_clock_expires` and no `due_date`. Add a one-line
   data-quality note (`<ticket_code>: waiting on <party>, no follow-up date set`). It is not a
   push and not stale. Ask the owner for a clock.

5. **`due_date` means our next action.** While an item waits, `due_date` is the follow-up date.
   Never describe it as the outside party's deadline, and never call an item "due today and
   unmoved" when it is waiting on track.

6. **Never infer chains or dependencies from title prefixes** (for example "Ticket D" or a
   shared `39P-0xx:` prefix). Read `public.work_item_links` (`blocks`, `blocked_by`,
   `relates_to`, `duplicates`). If there is no link, there is no chain.

### Tagging a new wait

When our action is complete and an outside party has the next move, set these keys in
`work_items.meta` (registered in `meta_key_registry`, owner System Architect):

| Key | Value | Required |
|---|---|---|
| `awaiting_external` | the party's name, e.g. `"NYC Parks Forestry"`. Any non-empty value other than `false` means waiting. | yes |
| `external_ref` | their reference, e.g. an SR number | no |
| `external_since` | `YYYY-MM-DD`, the day our action completed | recommended |
| `external_clock_expires` | `YYYY-MM-DD`, the day their window lapses, which is our follow-up date | recommended |

- Set `due_date` to the same follow-up date. If `external_clock_expires` is absent or
  malformed, the clock falls back to `due_date`.
- Optional (recommended, not enforced): move the ticket to `on_hold` with
  `hold_reason = 'awaiting external: <party>'`. This frees the WIP slot. The classifier
  ignores status, so a wait is recognised in any status.
- To end a wait, remove `awaiting_external` or set it to `false`. Do not leave the
  key as `''` or whitespace.
- Do not reuse `meta.blocked_on`. It still names a person or a step on our side.
- Tickets waiting on **Jason** are not external waits. They belong to the decision digest
  (SB-554), not to this rule.

---

## Pending backfills (Jason to confirm; not applied by SB-593)

- 39P-026: already classified correctly through `due_date` 2026-11-06. Proposed explicit keys:
  `external_since = 2026-10-07`, `external_clock_expires = 2026-11-06`.
- 39P-018, 39P-017, 39P-013: party and clock unknown. Jason to confirm before tagging.
- FAM-051: family data. Jason decides whether it is tagged at all.
