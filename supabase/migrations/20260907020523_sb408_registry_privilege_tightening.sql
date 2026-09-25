-- SB-408 follow-through (TC-SB408-V6): the project default ACL had already
-- handed `authenticated` every privilege on the three new tables before the
-- GRANT statements ran, so the grants were additive no-ops. Privileges are a
-- check distinct from RLS: leave authenticated only what the policies gate.
revoke all on table public.external_resource_catalog from authenticated;
grant select on table public.external_resource_catalog to authenticated;

revoke truncate, references, trigger on table public.external_connections,
                                         public.external_connection_resource_grants
  from authenticated;;
