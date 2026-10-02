-- CLSRM-39 part 3: make the handoff trigger fire when a hand-in is reported.
--
-- Parts 1 and 2 were correct and still did nothing a parent could see. The
-- trigger is declared AFTER INSERT OR UPDATE **OF** <fixed column list>
-- (tgattr = '11 10 7 5 4 6 16 18'), and that list predates these columns.
-- Reporting a hand-in therefore never woke the handoff: the reminder kept its
-- old title and priority until some LATER change to status or due_date
-- happened to fire the trigger and recompute it.
--
-- Found by an end-to-end probe, not by review. The symptom was a one-step lag:
-- reporting showed nothing, and the annotation appeared only after an unrelated
-- status change. Part 2's assertions inspected the function body and passed --
-- a function can be perfectly correct and simply never called.
--
-- Rather than extend the list again on the next column, drop the OF clause.
-- The function is idempotent, the table takes ~40 writes a day, and an
-- occasional redundant call is cheaper than another silently dead feature.

drop trigger if exists trg_school_assignment_to_fam on public.school_assignments;

create trigger trg_school_assignment_to_fam
after insert or update on public.school_assignments
for each row execute function public.tg_school_assignment_to_fam();

comment on function public.tg_school_assignment_to_fam() is
  'CLSRM-39: fires on ANY update to school_assignments, deliberately. The previous UPDATE OF column list went stale the moment columns were added and left the self-report feature inert — see CLSRM-39 part 3.';

do $$
declare col_list text; is_row boolean; is_enabled boolean;
begin
  -- pg_trigger.tgattr is an int2vector: empty string = no column restriction,
  -- space-separated attnums = restricted. It is NOT '{}' when empty.
  select tgattr::text, (tgtype::int & 1) = 1, tgenabled = 'O'
    into col_list, is_row, is_enabled
    from pg_trigger
   where tgrelid = 'public.school_assignments'::regclass
     and tgname  = 'trg_school_assignment_to_fam';

  if col_list is null then
    raise exception 'CLSRM-39: trg_school_assignment_to_fam is missing';
  end if;
  if col_list <> '' then
    raise exception 'CLSRM-39: the trigger still restricts to columns (tgattr=%)', col_list;
  end if;
  if not is_row then
    raise exception 'CLSRM-39: the trigger is not FOR EACH ROW';
  end if;
  if not is_enabled then
    raise exception 'CLSRM-39: the trigger is not enabled';
  end if;
end $$;;
