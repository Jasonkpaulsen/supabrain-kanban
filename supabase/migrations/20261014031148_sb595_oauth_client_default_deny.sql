-- SB-595 (ADR-API-002, SB-409; found by the SB-414 re-verification 2026-10-12).
-- SB-409 made the external OAuth client default-deny by adding a RESTRICTIVE
-- oauth_client_deny policy to every RLS-enabled public table that existed on
-- 2026-09-07. Nothing applied it to tables created afterwards, so 30 later tables
-- (the CRM, school_courses, the SB-412 connection controls, two registries) let an
-- OAuth session write rows as itself. Owner-only RLS kept every read at 0 rows.
--
-- 1. Backfill: the same policy, in the same form, on every public table that has
--    no oauth_client% policy. Granted tables (the SB-409 four-policy set) and the
--    write-denied connection registry are untouched: they already have oauth_client policies.
-- 2. Prevention: event trigger oauth_client_default_deny adds the policy to every
--    new public table (CREATE TABLE / CREATE TABLE AS / SELECT INTO) that has none.
--    Granting a table to the client stays explicit: replace the deny with the
--    SB-409 four-policy set in the same migration.
-- 3. Detection: vw_oauth_client_coverage_gaps lists public tables with no
--    oauth_client% policy. It must stay empty.
-- Direct sessions carry no client_id claim, so every deny short-circuits for them.

do $$
declare
  t record;
  n_added int := 0;
begin
  for t in
    select c.oid, c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname like 'oauth_client%')
    order by c.relname
  loop
    execute format('create policy oauth_client_deny on public.%I as restrictive for all to authenticated '
                   'using ((select public.oauth_client_id()) is null) with check ((select public.oauth_client_id()) is null)', t.relname);
    n_added := n_added + 1;
  end loop;
  raise notice 'SB-595: oauth_client_deny added to % tables', n_added;
end $$;

create or replace function public.oauth_client_default_deny()
returns event_trigger
language plpgsql
set search_path = ''
as $fn$
declare
  o record;
begin
  for o in
    select objid, object_identity
    from pg_event_trigger_ddl_commands()
    where object_type = 'table' and schema_name = 'public'
  loop
    if not exists (select 1 from pg_policy p where p.polrelid = o.objid and p.polname like 'oauth_client%') then
      execute format('create policy oauth_client_deny on %s as restrictive for all to authenticated '
                     'using ((select public.oauth_client_id()) is null) with check ((select public.oauth_client_id()) is null)',
                     o.object_identity);
    end if;
  end loop;
end
$fn$;

comment on function public.oauth_client_default_deny() is
  'SB-595: event trigger function. Every new public table gets the SB-409 RESTRICTIVE oauth_client_deny unless it already has an oauth_client% policy.';

revoke all on function public.oauth_client_default_deny() from public, anon, authenticated;

create event trigger oauth_client_default_deny
  on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.oauth_client_default_deny();

create or replace view public.vw_oauth_client_coverage_gaps
with (security_invoker = true) as
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p')
  and not exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname like 'oauth_client%');

comment on view public.vw_oauth_client_coverage_gaps is
  'SB-595: public tables with no oauth_client% policy. Must be empty: such a table is reachable by the external OAuth client (ADR-API-002).';

revoke all on public.vw_oauth_client_coverage_gaps from public, anon;
grant select on public.vw_oauth_client_coverage_gaps to authenticated, service_role;

-- assertions
do $$
declare
  gaps int; four int; trig int; ro int;
begin
  select count(*) into gaps from public.vw_oauth_client_coverage_gaps;
  if gaps <> 0 then raise exception 'SB-595: % public tables still have no oauth_client policy', gaps; end if;

  select count(*) into four from (
    select polrelid from pg_policy where polname in ('oauth_client_select','oauth_client_insert','oauth_client_update','oauth_client_delete')
    group by polrelid having count(*) = 4) x;
  if four <> 16 then raise exception 'SB-595: expected 16 granted tables with the SB-409 four-policy set, found %', four; end if;

  select count(*) into trig from pg_trigger where tgname = 'trg_oauth_client_immutable' and not tgisinternal;
  if trig <> 15 then raise exception 'SB-595: expected 15 trg_oauth_client_immutable triggers, found %', trig; end if;

  -- the connection registry stays readable by the client (the server checks its own connection) and write-denied
  select count(*) into ro from (
    select polrelid from pg_policy where polname in ('oauth_client_deny_insert','oauth_client_deny_update','oauth_client_deny_delete')
    group by polrelid having count(*) = 3) x;
  if ro <> 3 then raise exception 'SB-595: expected 3 write-denied connection registry tables, found %', ro; end if;

  if not exists (select 1 from pg_event_trigger where evtname = 'oauth_client_default_deny' and evtenabled = 'O' and evtevent = 'ddl_command_end') then
    raise exception 'SB-595: event trigger oauth_client_default_deny missing or disabled';
  end if;
end $$;
