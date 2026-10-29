-- SB-652 QA fixes (SupaBrain QA, comment c520c3c6, 2026-10-28), on top of 20261028151838.
--
-- 1. TC-SB652-13 FAIL: the guard trusted any session running as postgres, and every MCP session
--    runs as postgres, so any agent could insert a forged audit row. The audit functions now set
--    a transaction-local marker (sb652.audit_writer) around their own insert and clear it right
--    after, and the guard requires it. Honest limit, also written into the Standard: postgres
--    owns the table and can always disable a trigger, so this stops accidental and casual writes
--    by every role, not a deliberate owner.
-- 2. Design note 3 in 20261028151838 was wrong. Foreign-key cascades run their DELETE with
--    triggers deferred to the end of the outer statement, so a cascaded child's statement trigger
--    fires at depth 1, not below it. The depth branch therefore only ever ran for a DELETE issued
--    from inside another trigger. It is removed: every audited DELETE takes the same fail-open
--    path. Each cascaded child statement opens one subtransaction. That is a cost only for rare
--    bulk purges (deleting a project with hundreds of work items), and the Standard already says
--    to batch those. trigger_depth is still recorded.
-- 3. service_role kept write, TRUNCATE and TRIGGER privileges on the audit table and the view
--    through Supabase's default privileges. Removed. postgres keeps ownership and SELECT is
--    left for service_role.

revoke insert, update, delete, truncate, references, trigger on table public.sql_audit_log from service_role;
revoke insert, update, delete, truncate, references, trigger on table public.vw_destructive_sql_alerts from service_role;

create or replace function public.sql_audit_log_guard()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if tg_op = 'INSERT' and current_user = 'postgres'
     and current_setting('sb652.audit_writer', true) = 'on' then
    return new;
  end if;
  raise exception 'SB-652: sql_audit_log is append-only and written only by the audit functions' using errcode = '42501';
end
$function$;

create or replace function public.sql_audit_row_removal()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  n bigint;
begin
  begin
    select count(*) into n from removed_rows;
    if n > 0 then
      perform set_config('sb652.audit_writer', 'on', true);
      insert into public.sql_audit_log
        (operation, schema_name, object_name, object_type, rows_affected,
         db_role, session_role, auth_uid, application_name, trigger_depth)
      values
        ('delete', tg_table_schema, tg_table_name, 'table', n,
         coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
         public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), pg_trigger_depth());
      perform set_config('sb652.audit_writer', '', true);
    end if;
  exception when others then
    perform set_config('sb652.audit_writer', '', true);
    raise warning 'SB-652: delete audit failed on %.%: % (%)', tg_table_schema, tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end
$function$;

create or replace function public.sql_audit_truncation()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  begin
    perform set_config('sb652.audit_writer', 'on', true);
    insert into public.sql_audit_log
      (operation, schema_name, object_name, object_type, rows_affected,
       db_role, session_role, auth_uid, application_name, trigger_depth)
    values
      ('truncate', tg_table_schema, tg_table_name, 'table', null,
       coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
       public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), pg_trigger_depth());
    perform set_config('sb652.audit_writer', '', true);
  exception when others then
    perform set_config('sb652.audit_writer', '', true);
    raise warning 'SB-652: truncate audit failed on %.%: % (%)', tg_table_schema, tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end
$function$;

create or replace function public.sql_audit_object_removal()
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
    perform set_config('sb652.audit_writer', 'on', true);
    insert into public.sql_audit_log
      (operation, schema_name, object_name, object_type, rows_affected,
       db_role, session_role, auth_uid, application_name, trigger_depth)
    values
      ('drop', o.schema_name, coalesce(o.object_identity, o.object_name, '?'), o.object_type, null,
       coalesce(nullif(current_setting('role', true), 'none'), session_user::text), session_user::text,
       public.sql_audit_caller_uid(), nullif(current_setting('application_name', true), ''), 0);
    perform set_config('sb652.audit_writer', '', true);
  end loop;
exception when others then
  perform set_config('sb652.audit_writer', '', true);
  raise warning 'SB-652: drop audit failed: % (%)', sqlerrm, sqlstate;
end
$function$;
;
