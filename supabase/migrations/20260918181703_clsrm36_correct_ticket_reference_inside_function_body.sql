-- CLSRM-36 (third pass): finishes a correction the second one got wrong.
--
-- clsrm36_correct_ticket_reference_on_school_sync states "The function body
-- itself is unchanged and is not re-sent here; only the comment and the meta
-- strings carried the wrong reference." That is false. The body embeds the
-- literal 'CLSRM-13: machine-generated school reminder...' in the INSERT's
-- gate_exempt_reason, so every reminder raised after that migration carried the
-- wrong ticket reference again -- six of them did, on 2026-09-18.
--
-- Rather than re-typing 8 KB of function body and risking an unrelated
-- difference, the definition is read back from the catalog with
-- pg_get_functiondef, the reference corrected in place, and the result
-- executed. Same technique SB-439 used to rebuild objects faithfully.

do $$
declare def text; n int;
begin
  select pg_get_functiondef('public.sync_school_assignment_to_fam(uuid)'::regprocedure) into def;

  if position('CLSRM-13' in def) = 0 then
    raise notice 'CLSRM-36: no stale reference in the function body; nothing to do';
  else
    def := replace(def, 'CLSRM-13', 'CLSRM-36');
    execute def;
  end if;

  -- reminders raised between the second and third pass
  update public.work_items
  set meta = jsonb_set(meta, '{gate_exempt_reason}',
               to_jsonb('CLSRM-36: machine-generated school reminder; auto-resolved from Classroom state, nothing for a human to review'::text))
  where source_table = 'school_assignments'
    and meta->>'gate_exempt_reason' like 'CLSRM-13:%';

  -- assert: no stale reference left in the body, in any reminder, or in the comment
  if position('CLSRM-13' in (select prosrc from pg_proc
                             where oid = 'public.sync_school_assignment_to_fam(uuid)'::regprocedure)) > 0 then
    raise exception 'CLSRM-36: function body still references CLSRM-13';
  end if;

  select count(*) into n from public.work_items
  where source_table = 'school_assignments' and meta->>'gate_exempt_reason' like 'CLSRM-13:%';
  if n > 0 then
    raise exception 'CLSRM-36: % reminder(s) still reference CLSRM-13', n;
  end if;

  -- and the fix this whole ticket exists for is still in force
  select count(*) into n from public.work_items
  where source_table = 'school_assignments'
    and coalesce(meta->>'review_gate_exempt','false') <> 'true';
  if n > 0 then
    raise exception 'CLSRM-36: % reminder(s) lost review_gate_exempt', n;
  end if;

  if (select prosecdef from pg_proc
      where oid = 'public.sync_school_assignment_to_fam(uuid)'::regprocedure) is not true then
    raise exception 'CLSRM-36: sync_school_assignment_to_fam lost SECURITY DEFINER';
  end if;
end $$;;
