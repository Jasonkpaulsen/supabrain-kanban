-- SB-554 / SB-526 (ADR-FLOW-005 D6-D8): client-role grants for the decision digest and the
-- escalation closure audit.
--
-- The project's default privileges give new public functions and views to postgres and
-- service_role only, so after 20261014111004 and 20261014114114 the authenticated role could
-- not read either view, jason_decision_digest() failed with 42501, and for authenticated
-- writers both work_items triggers failed open in silence (no meta.blocker_class, no
-- meta.escalation_snapshot, no closure verdict) because the helper functions they call were
-- not executable. Both views are security_invoker and the helpers are security invoker, so
-- work_items RLS still scopes every row to its owner. anon stays without access.

grant select on public.vw_jason_decision_digest to authenticated, service_role;
grant select on public.vw_escalation_closure_audit to authenticated, service_role;
revoke all on public.vw_jason_decision_digest from anon;
revoke all on public.vw_escalation_closure_audit from anon;

revoke execute on function public.escalation_gate_mode(text) from public, anon;
revoke execute on function public.escalation_subject_codes(jsonb) from public, anon;
revoke execute on function public.jason_blocker_class(text[]) from public, anon;
revoke execute on function public.escalation_open_blockers(uuid) from public, anon;
grant execute on function public.escalation_gate_mode(text) to authenticated, service_role;
grant execute on function public.escalation_subject_codes(jsonb) to authenticated, service_role;
grant execute on function public.jason_blocker_class(text[]) to authenticated, service_role;
grant execute on function public.escalation_open_blockers(uuid) to authenticated, service_role;

do $$
declare
  v_fn  text;
  v_vw  text;
  n_dig int;
  n_aud int;
  v_tot text;
begin
  foreach v_vw in array array['public.vw_jason_decision_digest', 'public.vw_escalation_closure_audit'] loop
    if not has_table_privilege('authenticated', v_vw, 'select')
       or not has_table_privilege('service_role', v_vw, 'select') then
      raise exception 'SB-554 grants: % is not selectable by authenticated and service_role', v_vw;
    end if;
    if has_table_privilege('anon', v_vw, 'select') then
      raise exception 'SB-554 grants: % is selectable by anon', v_vw;
    end if;
    if not exists (select 1 from pg_class where oid = v_vw::regclass
                     and reloptions @> array['security_invoker=true']) then
      raise exception 'SB-554 grants: % lost security_invoker', v_vw;
    end if;
  end loop;

  foreach v_fn in array array['public.escalation_gate_mode(text)', 'public.escalation_subject_codes(jsonb)',
                              'public.jason_blocker_class(text[])', 'public.escalation_open_blockers(uuid)',
                              'public.jason_decision_digest()'] loop
    if not has_function_privilege('authenticated', v_fn, 'execute')
       or not has_function_privilege('service_role', v_fn, 'execute') then
      raise exception 'SB-554 grants: % is not executable by authenticated and service_role', v_fn;
    end if;
    if has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'SB-554 grants: % is executable by anon', v_fn;
    end if;
    if exists (select 1 from pg_proc where oid = v_fn::regprocedure and prosecdef) then
      raise exception 'SB-554 grants: % must stay security invoker', v_fn;
    end if;
  end loop;

  if public.escalation_gate_mode('SB-554') <> 'warn' or public.escalation_gate_mode('SB-526') <> 'warn' then
    raise exception 'SB-554 grants: escalation_gate_mode must return warn until Jason approves';
  end if;

  -- behaviour: the owner's authenticated session can read both views and call the digest
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n_dig from public.vw_jason_decision_digest;
  select count(*) into n_aud from public.vw_escalation_closure_audit;
  v_tot := public.jason_decision_digest()->>'total';
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  if v_tot is null or v_tot::int <> n_dig then
    raise exception 'SB-554 grants: owner session digest total % does not match the view (%)', v_tot, n_dig;
  end if;
  if n_dig > (select count(*) from public.vw_jason_decision_digest) then
    raise exception 'SB-554 grants: owner session sees more digest rows than postgres';
  end if;
end $$;
