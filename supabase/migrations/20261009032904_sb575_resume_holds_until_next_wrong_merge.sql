-- SB-575 QA defect D1 (TC-SB575-6): a resume did not hold. crm_steward_record_verdict re-evaluated the
-- windowed wrong-merge rate on every call, and the wrong verdict that tripped the suspension stays in
-- the window, so the next verdict of any kind (even a correct one, even on an auto_confirm)
-- re-suspended auto-merge right after Jason's resume.
--
-- Fix: evaluate only when a WRONG verdict lands on an AUTO_MERGE. A correct verdict, or a verdict on
-- any other decision type, can never raise the wrong-merge rate (it adds a correct, supersedes a wrong,
-- or slides out an older verdict), so nothing that should suspend is missed. A resume now holds until
-- a new wrong merge is found (ADR-CRM-006 §7: "holds until Jason or QA writes a resume row").
-- The rest of the function is unchanged (patched in place; refuses unless the deployed body is
-- SB-575's, md5 cd6c690d850a0e3941f2d964f503f75e).

do $patch$
declare
  v_def text;
  v_old constant text := $o$  if v_n > 0 and v_wrong::numeric / v_n > 0.02 and not public.crm_steward_suspended() then$o$;
  v_new constant text := $o$  -- only a wrong merge verdict can raise the rate; a resume holds until the next one (SB-575 D1)
  if p_verdict = 'wrong' and v_dec = 'auto_merge'
     and v_n > 0 and v_wrong::numeric / v_n > 0.02 and not public.crm_steward_suspended() then$o$;
begin
  if (select md5(prosrc) from pg_proc where oid = 'public.crm_steward_record_verdict(uuid,text,text)'::regprocedure)
       <> 'cd6c690d850a0e3941f2d964f503f75e' then
    raise exception 'SB-575 fix: crm_steward_record_verdict is not the SB-575 body; refusing to patch';
  end if;
  v_def := pg_get_functiondef('public.crm_steward_record_verdict(uuid,text,text)'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'SB-575 fix: expected exactly one suspension condition in crm_steward_record_verdict';
  end if;
  execute replace(v_def, v_old, v_new);
end $patch$;

do $chk$
begin
  if (select prosrc from pg_proc where oid = 'public.crm_steward_record_verdict(uuid,text,text)'::regprocedure)
       !~ $r$p_verdict = 'wrong' and v_dec = 'auto_merge'$r$ then
    raise exception 'A1: auto-suspend must be evaluated only on a wrong merge verdict';
  end if;
  if exists (select 1 from pg_proc where oid = 'public.crm_steward_record_verdict(uuid,text,text)'::regprocedure
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_steward_record_verdict(uuid,text,text)', 'execute') then
    raise exception 'A2: crm_steward_record_verdict must stay SECURITY INVOKER, pinned, and closed to anon';
  end if;
end $chk$;
