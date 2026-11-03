-- SB-448: restore the three RPCs the Denken Box iOS client calls on every load —
-- get_schema_info(), get_table_counts(), get_dashboard_activity(int) — without
-- reintroducing the exposure that got them revoked.
--
-- History: all three were SECURITY DEFINER with no user predicate. get_dashboard_activity
-- returned every user's memories/decisions/conversations; get_table_counts counted every
-- row in every table past RLS; get_schema_info exposed the full schema to any signed-in
-- user. SB-128 (SEC-009) revoked authenticated EXECUTE on 2026-08-11 — correctly, on the
-- evidence — but the caller check covered only this repo's three front ends. Denken Box
-- is an external client ("bring your own Supabase") whose project description names
-- get_schema_info() as its schema-introspection path. It has been failing with
-- 42501 ("can't reflect tables") since.
--
-- Fix: SECURITY INVOKER. The caller's own grants and RLS decide what each function sees:
--   get_schema_info      -> information_schema shows only tables the caller has privileges on
--   get_table_counts     -> counts only RLS-visible rows; tables without SELECT are skipped
--   get_dashboard_activity -> memories/decisions/conversations filtered by their own policies
-- Nothing here grants a row the caller could not already read through PostgREST.

create or replace function public.get_schema_info()
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  result jsonb;
begin
  select jsonb_agg(t_info order by t_info->>'table_name')
  into result
  from (
    select jsonb_build_object(
      'table_name', t.table_name,
      'columns', (
        select jsonb_agg(
          jsonb_build_object(
            'column_name', c.column_name,
            'data_type', c.data_type,
            'udt_name', c.udt_name,
            'is_nullable', c.is_nullable,
            'column_default', c.column_default,
            'ordinal_position', c.ordinal_position
          )
          order by c.ordinal_position
        )
        from information_schema.columns c
        where c.table_schema = 'public'
          and c.table_name = t.table_name
      ),
      'check_constraints', (
        select jsonb_agg(jsonb_build_object(
          'column_name', a.attname,
          'allowed_values', (
            select jsonb_agg(val order by val)
            from (
              select unnest(regexp_matches(pg_get_constraintdef(con.oid), '''([^'']+)''', 'g')) as val
            ) extracted
          )
        ))
        from pg_constraint con
        join pg_attribute a on a.attnum = any(con.conkey) and a.attrelid = con.conrelid
        where con.conrelid = (
          select oid from pg_class
          where relname = t.table_name
            and relnamespace = (select oid from pg_namespace where nspname = 'public')
        )
        and con.contype = 'c'
        and pg_get_constraintdef(con.oid) like '%ANY%ARRAY%'
      )
    ) as t_info
    from information_schema.tables t
    where t.table_schema = 'public'
      and t.table_type = 'BASE TABLE'
  ) sub;

  return coalesce(result, '[]'::jsonb);
end;
$function$;

create or replace function public.get_table_counts()
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  result jsonb := '{}'::jsonb;
  tbl record;
  cnt bigint;
  has_archived boolean;
begin
  for tbl in
    select table_name from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE'
  loop
    begin
      select exists(
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = tbl.table_name and column_name = 'archived'
      ) into has_archived;

      if has_archived then
        execute format('select count(*) from public.%I where archived = false', tbl.table_name) into cnt;
      else
        execute format('select count(*) from public.%I', tbl.table_name) into cnt;
      end if;

      result := result || jsonb_build_object(tbl.table_name, cnt);
    exception when insufficient_privilege then
      -- caller cannot read this table; leave it out rather than fail the whole dashboard
      null;
    end;
  end loop;

  return result;
end;
$function$;

create or replace function public.get_dashboard_activity(item_limit integer default 5)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
declare
  result jsonb := '{}'::jsonb;
  mem_data jsonb;
  dec_data jsonb;
  conv_data jsonb;
begin
  select coalesce(jsonb_agg(row_to_json(m)), '[]'::jsonb) into mem_data
  from (
    select id, type, content, importance, created_at
    from public.memories where archived = false
    order by created_at desc limit item_limit
  ) m;

  select coalesce(jsonb_agg(row_to_json(d)), '[]'::jsonb) into dec_data
  from (
    select id, title, decision, created_at
    from public.decisions where archived = false
    order by created_at desc limit item_limit
  ) d;

  select coalesce(jsonb_agg(row_to_json(c)), '[]'::jsonb) into conv_data
  from (
    select id, title, summary, created_at
    from public.conversations where archived = false
    order by created_at desc limit item_limit
  ) c;

  return jsonb_build_object('memories', mem_data, 'decisions', dec_data, 'conversations', conv_data);
end;
$function$;

-- ACL: set explicitly by role name (REVOKE FROM PUBLIC alone leaves default-ACL grants in place).
revoke all on function public.get_schema_info() from public, anon;
revoke all on function public.get_table_counts() from public, anon;
revoke all on function public.get_dashboard_activity(integer) from public, anon;
grant execute on function public.get_schema_info() to authenticated, service_role;
grant execute on function public.get_table_counts() to authenticated, service_role;
grant execute on function public.get_dashboard_activity(integer) to authenticated, service_role;

comment on function public.get_schema_info() is
  'SB-448: SECURITY INVOKER schema introspection for Denken Box. Shows only tables the caller holds privileges on. Do not convert back to DEFINER without a user predicate.';
comment on function public.get_table_counts() is
  'SB-448: SECURITY INVOKER; counts only rows visible to the caller under RLS, skips tables the caller cannot read.';
comment on function public.get_dashboard_activity(integer) is
  'SB-448: SECURITY INVOKER; memories/decisions/conversations scoped by the caller''s own RLS policies.';

do $$
declare f text;
begin
  foreach f in array array['public.get_schema_info()','public.get_table_counts()','public.get_dashboard_activity(integer)'] loop
    if (select prosecdef from pg_proc where oid = f::regprocedure) then
      raise exception 'SB-448: % is still SECURITY DEFINER', f;
    end if;
    if has_function_privilege('anon', f, 'execute') then
      raise exception 'SB-448: anon can execute %', f;
    end if;
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'SB-448: authenticated cannot execute %', f;
    end if;
  end loop;
end $$;;
