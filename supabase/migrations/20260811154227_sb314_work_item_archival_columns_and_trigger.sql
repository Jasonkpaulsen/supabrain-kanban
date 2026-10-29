-- ADR-FLOW-003 §2, §4.4 — archival flag + the re-open trap guard.
alter table public.work_items
  add column if not exists archived boolean not null default false,
  add column if not exists archived_at timestamptz;

comment on column public.work_items.archived is
  'ADR-FLOW-003: display-only archival flag. archived = true implies status = ''done'' (enforced by trg_archived_implies_done). Never filtered in metrics/audit views.';
comment on column public.work_items.archived_at is
  'ADR-FLOW-003: when the row was archived. Cleared on un-archive and on re-open.';

-- §4.4: move_work_item nulls completed_at on any move off done and never touches
-- archived; index.html PATCHes status directly and bypasses the RPC entirely.
-- A BEFORE UPDATE trigger is the only complete fix for the re-open trap.
create or replace function public.enforce_archived_implies_done()
returns trigger
language plpgsql
as $$
begin
  if new.status <> 'done' and new.archived then
    new.archived := false;
    new.archived_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_archived_implies_done on public.work_items;
create trigger trg_archived_implies_done
  before update on public.work_items
  for each row
  execute function public.enforce_archived_implies_done();;
