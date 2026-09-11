-- SB-443: both functions were granted EXECUTE to anon by the SB-412 migration
-- (20260909022151_sb412_external_connection_audit_and_controls). Neither is ever called by an
-- unauthenticated caller: the gateway edge function calls precheck as service_role, and the
-- kill switch is used by a signed-in owner.
--
-- set_external_connection_status was already safe in practice -- it makes the owner check
-- explicitly in its body because it is SECURITY DEFINER -- but it still leaked an existence
-- bit through its error code (P0002 not-found vs 42501 owner-only).
--
-- external_connection_precheck had no caller check at all, so anon could learn whether a
-- connection id existed, its status, and its rate-limit state including retry-after.
--
-- Guarded so the migration is a no-op if either function is absent, keeping a fresh replay
-- from failing.
do $$
begin
  if to_regprocedure('public.external_connection_precheck(uuid, text)') is not null then
    execute 'revoke execute on function public.external_connection_precheck(uuid, text) from anon';
  end if;
  if to_regprocedure('public.set_external_connection_status(uuid, text, text)') is not null then
    execute 'revoke execute on function public.set_external_connection_status(uuid, text, text) from anon';
  end if;
end $$;;
