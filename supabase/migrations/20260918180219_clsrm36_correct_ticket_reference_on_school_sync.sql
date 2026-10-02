-- CLSRM-36: corrects a naming error in the immediately preceding migration
-- (clsrm13_school_sync_review_gate_exempt_and_isolation).
--
-- That migration labels the fix "CLSRM-13" throughout. CLSRM-13 is an unrelated
-- closed ticket about scraping assignment detail pages; the next free number in
-- the sequence was CLSRM-36. The applied migration is left as it stands rather
-- than edited, because the repo file must stay byte-identical to the stored
-- statement (SB-437). This migration corrects the live artifacts it left behind:
-- the function comment and the meta reason on the 13 backfilled reminders.
--
-- The function body itself is unchanged and is not re-sent here; only the
-- comment and the meta strings carried the wrong reference.

comment on function public.sync_school_assignment_to_fam(uuid) is
  'CLSRM-36: mirrors a Classroom assignment onto the FAM board and calendar. The work_items half is exception-isolated — a gate refusal logs a WARNING and skips that handoff rather than aborting the daily sweep. Reminders carry qa_gate_exempt and review_gate_exempt because they are machine-generated and machine-resolved. (The migration that introduced this is named clsrm13_… in error; the ticket is CLSRM-36.)';

update public.work_items
set meta = jsonb_set(meta, '{gate_exempt_reason}',
             to_jsonb('CLSRM-36: machine-generated school reminder; auto-resolved from Classroom state, nothing for a human to review'::text))
where source_table = 'school_assignments'
  and meta->>'gate_exempt_reason' like 'CLSRM-13:%';

do $$
declare n_stale int;
begin
  select count(*) into n_stale
  from public.work_items
  where source_table = 'school_assignments'
    and meta->>'gate_exempt_reason' like 'CLSRM-13:%';
  if n_stale > 0 then
    raise exception 'CLSRM-36: % reminder(s) still carry the wrong ticket reference', n_stale;
  end if;

  -- the fix itself must still be in force
  if exists (
    select 1 from public.work_items
    where source_table = 'school_assignments'
      and coalesce(meta->>'review_gate_exempt','false') <> 'true'
  ) then
    raise exception 'CLSRM-36: a school reminder lost review_gate_exempt';
  end if;
end $$;;
