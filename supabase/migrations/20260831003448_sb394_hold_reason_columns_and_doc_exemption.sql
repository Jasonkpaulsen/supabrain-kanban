
-- SB-394. Correction to the ticket's premise, found on execution: the record is
-- NOT absent. Both WIP triggers already write meta.hold_reason, covering 7 of the
-- 29 on_hold items. What is actually wrong is that ONE field carries two kinds of
-- value — a machine code ('review_wip_limit') and human prose ('Jason deferred —
-- revisit in 3 months') — so no consumer can tell a gate redirect from a person's
-- decision without pattern-matching English. The two-column split fixes that.
alter table public.work_items
  add column if not exists hold_reason  text,
  add column if not exists held_by_gate text;

comment on column public.work_items.hold_reason is
  'Why this item is on_hold, in a person''s words. Null when a gate parked it — see held_by_gate.';
comment on column public.work_items.held_by_gate is
  'Name of the trigger that redirected this item to on_hold (e.g. enforce_review_wip_limit). Set by the gate, never by hand. Null means a person parked it.';

-- Migrate what meta already holds: machine codes to held_by_gate, prose to hold_reason.
update public.work_items
   set held_by_gate = case meta->>'hold_reason'
                        when 'wip_limit'        then 'enforce_wip_limit'
                        when 'review_wip_limit' then 'enforce_review_wip_limit'
                      end
 where meta->>'hold_reason' in ('wip_limit','review_wip_limit');

update public.work_items
   set hold_reason = meta->>'hold_reason'
 where meta ? 'hold_reason'
   and meta->>'hold_reason' not in ('wip_limit','review_wip_limit');

-- The 22 with nothing recorded stay honest rather than guessed.
update public.work_items
   set hold_reason = 'unknown — parked before SB-394 recorded a reason'
 where status = 'on_hold' and not archived
   and hold_reason is null and held_by_gate is null;

-- Retire the meta key now that both halves have columns.
update public.work_items set meta = meta - 'hold_reason' where meta ? 'hold_reason';
;
