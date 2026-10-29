-- SB-321: completed_at was maintained by move_work_item, so every writer that
-- skipped the RPC (the edit modal, agent-runner, direct SQL) skipped the timestamp.
-- Moving it onto the table makes it unbypassable, which is the same reason
-- trg_archived_implies_done exists.
create or replace function public.maintain_completed_at()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if TG_OP = 'INSERT' then
    -- A row can be created directly into done (the new-item form carries the same
    -- status dropdown). An explicit completed_at is respected so data loads keep theirs.
    if new.status = 'done' then
      new.completed_at := coalesce(new.completed_at, now());
    end if;
    return new;
  end if;

  if new.status = 'done' and old.status is distinct from 'done' then
    -- now(), NOT coalesce(completed_at, now()): a re-finished ticket must restart its
    -- 14-day hold rather than inherit an expired one. This is the one place the trigger
    -- deliberately differs from move_work_item, whose coalesce is what let the stale
    -- date survive a round trip (OB-003: done today, completed_at 94 days old).
    new.completed_at := now();
  elsif old.status = 'done' and new.status is distinct from 'done' then
    new.completed_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_completed_at on public.work_items;
create trigger trg_completed_at
  before insert or update on public.work_items
  for each row execute function public.maintain_completed_at();

-- Same INSERT hole in the §4.4 invariant: an insert carrying archived=true with a
-- non-done status would slip past a BEFORE UPDATE trigger. Nothing does that today,
-- but it is the identical defect class and cheap to close here.
drop trigger if exists trg_archived_implies_done on public.work_items;
create trigger trg_archived_implies_done
  before insert or update on public.work_items
  for each row execute function public.enforce_archived_implies_done();;
