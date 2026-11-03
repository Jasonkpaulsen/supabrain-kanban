-- SB-593 follow-up (verifier finding, ADR-FLOW-005 D2): read-only roles lost EXECUTE
-- on the two wait-state functions when 20261014111002 took EXECUTE away from PUBLIC.
-- pg_read_all_data members (supabase_read_only_user, supabase_etl_admin) can SELECT
-- vw_audit_health_checks, jarvis_ops_metrics, v_review_dwell_alerts,
-- v_review_sla_breaches and v_review_breaches_by_assignee, and those views call the
-- functions, so reads through those roles would raise 42501. Both functions are
-- SECURITY INVOKER, STABLE and read only their arguments. PUBLIC stays without EXECUTE.

grant execute on function public.external_wait_clock(jsonb, date) to pg_read_all_data;
grant execute on function public.work_item_wait_state(jsonb, date, date) to pg_read_all_data;

do $assert$
declare
  v_n int;
begin
  select count(*) into v_n from pg_proc p
   where p.oid in ('public.external_wait_clock(jsonb,date)'::regprocedure,
                   'public.work_item_wait_state(jsonb,date,date)'::regprocedure)
     and has_function_privilege('pg_read_all_data', p.oid, 'execute')
     and has_function_privilege('supabase_read_only_user', p.oid, 'execute')
     and has_function_privilege('supabase_etl_admin', p.oid, 'execute')
     and has_function_privilege('anon', p.oid, 'execute')
     and has_function_privilege('authenticated', p.oid, 'execute')
     and has_function_privilege('service_role', p.oid, 'execute')
     and not p.prosecdef
     and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0);
  if v_n <> 2 then raise exception 'SB-593 grants: % of 2 functions have the expected EXECUTE posture', v_n; end if;

  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relname in ('vw_audit_health_checks', 'jarvis_ops_metrics', 'v_review_dwell_alerts',
                       'v_review_sla_breaches', 'v_review_breaches_by_assignee')
     and has_table_privilege('supabase_read_only_user', c.oid, 'select');
  if v_n <> 5 then raise exception 'SB-593 grants: read-only role selects % of 5 views', v_n; end if;
end
$assert$;
