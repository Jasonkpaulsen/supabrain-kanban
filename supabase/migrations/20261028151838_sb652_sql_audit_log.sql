-- SB-652: audit destructive SQL (DELETE, TRUNCATE, DROP) before SB-651 removes the Supabase
-- connector's destructive-SQL confirmation (decision 0370d2fd, accepted by Jason 2026-10-28).
--
-- Today the confirmation stops destructive statements by accident: Jason's clients never render
-- it, so the statement hangs 180s and rolls back. Once SB-651 skips it for execute_sql, an agent's
-- DELETE, TRUNCATE or DROP runs at once. This migration makes every such statement leave a record.
--
-- Design notes (System Architect, recorded on SB-652):
-- 1. A dedicated append-only table, not activity_log. activity_log's action CHECK has no
--    delete or drop values (widening it means dropping the constraint) and it requires a
--    project_id. Shape follows external_connection_audit_log: no user_id or updated_at, and no
--    row content, because these tables hold PII.
-- 2. Fail-open at the top level: if writing an audit row fails, the trigger raises a WARNING and
--    the caller's statement still succeeds. CLSRM-36 is why: an unhandled trigger exception took
--    the Classroom sweep down for six days. A gap in the audit shows up as a WARNING in the logs.
-- 3. Foreign-key cascades run one DELETE per parent row, so a cascade can fire these statement
--    triggers hundreds of times in one transaction. Below the top level (pg_trigger_depth() > 1)
--    the row is written without an exception block, so a large cascade does not open hundreds of
--    subtransactions. The alerts view sums rows per transaction, so a cascade still counts as one.
-- 4. Who ran it: current_setting('role') is the caller's role even inside SECURITY DEFINER
--    (PostgREST's SET ROLE), plus session_user and the JWT subject. sql_audit_caller_uid() reads
--    the subject with pg_input_is_valid, so it cannot raise.
-- 5. The DROP event trigger function follows SB-595's oauth_client_default_deny exactly: plain
--    plpgsql, no SECURITY DEFINER, search_path ''. DDL here is run by postgres, which owns the
--    audit table. DDL by superusers (supabase_admin) does not fire non-superuser event triggers.
-- 6. Only the audit functions write audit rows: a BEFORE INSERT guard refuses every other writer,
--    including service_role. UPDATE, DELETE and TRUNCATE are refused for everyone.
-- 7. No DO blocks here: the hosted MCP's confirmation treats DO blocks as destructive, which is
--    the hang SB-651 removes. The assertions live in supabase/tests/sql_audit_suite.sql.
-- 8. No client grants: SB-488 defaults leave anon and authenticated with nothing on new objects,
--    and SB-595's event trigger adds the restrictive oauth_client_deny policy to the new table.
-- 9. Known blind spot: with session_replication_role = replica, ordinary triggers do not fire, so
--    those statements are not audited. Nothing in this ecosystem runs in replica mode today.

create table public.sql_audit_log (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  operation        text not null check (operation in ('delete', 'truncate', 'drop')),
  schema_name      text not null,
  object_name      text not null,
  object_type      text not null,
  rows_affected    bigint,
  db_role          text not null,
  session_role     text not null,
  auth_uid         uuid,
  application_name text,
  trigger_depth    int not null default 0,
  txid             bigint not null default (pg_current_xact_id()::text::bigint)
);

comment on table public.sql_audit_log is
  'SB-652: one row per destructive statement (DELETE with rows, TRUNCATE, DROP) on audited public objects. Append-only. Written only by the sql_audit_* functions. Counts and identities only, never row content.';

create index sql_audit_log_created_at_idx on public.sql_audit_log (created_at desc);

alter table public.sql_audit_log enable row level security;

-- The JWT subject as a uuid, or null. Never raises.
create function public.sql_audit_caller_uid()
returns uuid
language sql
stable
set search_path to ''
as $function$
  select case when pg_input_is_valid(s, 'uuid') then s::uuid end
    from (select coalesce(
                   nullif(current_setting('request.jwt.claim.sub', true), ''),
                   case when pg_input_is_valid(nullif(current_setting('request.jwt.claims', true), ''), 'jsonb')
                        then (current_setting('request.jwt.claims', true)::jsonb ->> 'sub') end
                 ) as s) x
$function$;

-- Guard: inserts only from the audit functions (which run as postgres), nothing else ever.
create function public.sql_audit_log_guard()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if tg_op = 'INSERT' and current_user = 'postgres' then
    return new;
  end if;
  raise exception 'SB-652: sql_audit_log is append-only and written only by the audit functions' using errcode = '42501';
end
$function$;

create trigger sql_audit_log_guard
  before insert or update or delete on public.sql_audit_log
  for each row execute function public.sql_audit_log_guard();

create trigger sql_audit_log_no_truncate
  before truncate on public.sql_audit_log
  for each statement execute function public.sql_audit_log_guard();

-- Statement-level DELETE audit. One row per statement that removed at least one row.
create function public.sql_audit_row_removal()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  n bigint;
  d int := pg_trigger_depth();
begin
  if d > 1 then
    -- inside a cascade: no subtransaction (design note 3)
    select count(*) into n from removed_rows;
    if n > 0 then
      insert into public.sql_audit_log
        (operation, schema_name, object_name, object_type, rows_affected,
         db_role, session_role, auth_uid, application_name, trigger_depth)
      values
        ('delete', tg_table_schema, tg_table_name, 'table', n,
         coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
         public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), d);
    end if;
    return null;
  end if;
  begin
    select count(*) into n from removed_rows;
    if n > 0 then
      insert into public.sql_audit_log
        (operation, schema_name, object_name, object_type, rows_affected,
         db_role, session_role, auth_uid, application_name, trigger_depth)
      values
        ('delete', tg_table_schema, tg_table_name, 'table', n,
         coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
         public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), d);
    end if;
  exception when others then
    raise warning 'SB-652: delete audit failed on %.%: % (%)', tg_table_schema, tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end
$function$;

-- TRUNCATE audit. Row count is not available to a TRUNCATE trigger.
create function public.sql_audit_truncation()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  begin
    insert into public.sql_audit_log
      (operation, schema_name, object_name, object_type, rows_affected,
       db_role, session_role, auth_uid, application_name, trigger_depth)
    values
      ('truncate', tg_table_schema, tg_table_name, 'table', null,
       coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
       public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), pg_trigger_depth());
  exception when others then
    raise warning 'SB-652: truncate audit failed on %.%: % (%)', tg_table_schema, tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end
$function$;

-- DROP audit: every object in public that a DDL statement names directly (original = true), so
-- DROP TABLE, DROP FUNCTION, DROP POLICY, ALTER TABLE ... DROP COLUMN and so on. Dependent objects
-- dropped along with them (indexes, constraints, triggers) are not listed separately.
-- The whole body is exception-safe: an event trigger that raises would block all DDL.
create function public.sql_audit_object_removal()
returns event_trigger
language plpgsql
set search_path to ''
as $function$
declare
  o record;
begin
  for o in
    select d.schema_name, d.object_name, d.object_identity, d.object_type
      from pg_event_trigger_dropped_objects() d
     where d.original and not d.is_temporary and d.schema_name = 'public'
  loop
    insert into public.sql_audit_log
      (operation, schema_name, object_name, object_type, rows_affected,
       db_role, session_role, auth_uid, application_name, trigger_depth)
    values
      ('drop', o.schema_name, coalesce(o.object_identity, o.object_name, '?'), o.object_type, null,
       coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
       public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), 0);
  end loop;
exception when others then
  raise warning 'SB-652: drop audit failed: % (%)', sqlerrm, sqlstate;
end
$function$;

create event trigger sql_audit_object_removal
  on sql_drop
  execute function public.sql_audit_object_removal();

-- The twelve core tables named in SB-652.
create trigger sql_audit_row_removal after delete on public.work_items
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.work_items
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.work_item_comments
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.work_item_comments
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.agents
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.agents
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.skills
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.skills
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.projects
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.projects
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.decisions
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.decisions
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.memories
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.memories
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.reference_items
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.reference_items
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.test_cases
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.test_cases
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.test_runs
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.test_runs
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.image_assets
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.image_assets
  for each statement execute function public.sql_audit_truncation();

create trigger sql_audit_row_removal after delete on public.image_requests
  referencing old table as removed_rows for each statement execute function public.sql_audit_row_removal();
create trigger sql_audit_truncation after truncate on public.image_requests
  for each statement execute function public.sql_audit_truncation();

-- What the JARVIS evening sweep reads (SB-652 step 3). One row per transaction and object: any
-- DROP or TRUNCATE, and any DELETE that removed more than 25 rows from one table in total,
-- cascades included. Read over MCP as postgres. It deliberately has no client grants: do not
-- grant it to authenticated.
create view public.vw_destructive_sql_alerts
with (security_invoker = true) as
select min(created_at) as first_at, operation, schema_name, object_name, object_type,
       sum(rows_affected) as rows_affected, count(*) as statements,
       min(db_role) as db_role, min(session_role) as session_role, min(auth_uid::text) as auth_uid,
       min(application_name) as application_name, txid
  from public.sql_audit_log
 where created_at > now() - interval '24 hours'
 group by txid, operation, schema_name, object_name, object_type
having operation in ('truncate', 'drop') or sum(rows_affected) > 25
 order by min(created_at) desc;

comment on view public.vw_destructive_sql_alerts is
  'SB-652: destructive statements in the last 24h worth a human look, one row per transaction and object. Read by the JARVIS evening sweep over MCP as postgres. No client grants by design.';
;
