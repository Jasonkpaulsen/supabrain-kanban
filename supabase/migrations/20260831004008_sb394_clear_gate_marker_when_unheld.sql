
-- SB-394 defect found in its own verification: the gates SET held_by_gate but
-- nothing cleared it, so an item that later left on_hold kept the marker and the
-- board would badge a card that is no longer held. A one-way flag is how the
-- staleness in this whole epic starts.
create or replace function public.clear_hold_marker_on_unhold()
returns trigger
language plpgsql
set search_path to 'public'
as $fn$
begin
  -- Only when leaving on_hold, and only if a gate did not just re-park it.
  if old.status = 'on_hold' and new.status is distinct from 'on_hold' then
    new.held_by_gate := null;
    new.hold_reason  := null;
  end if;
  return new;
end;
$fn$;

-- AFTER the WIP gates, so a same-statement redirect back into on_hold wins.
drop trigger if exists trg_zz_clear_hold_marker on public.work_items;
create trigger trg_zz_clear_hold_marker
  before update of status on public.work_items
  for each row execute function public.clear_hold_marker_on_unhold();
;
