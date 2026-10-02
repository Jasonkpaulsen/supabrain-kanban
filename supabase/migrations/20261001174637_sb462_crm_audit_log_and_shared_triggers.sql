-- SB-462 (ADR-CRM-001 §6): the CRM audit log and the shared CRM trigger functions.
--
-- This goes first so that every CRM table created after it is born audited.
--
-- crm_audit_log records WHAT happened to WHICH row, by WHOM and HOW it ended. It has
-- no column able to hold a name, a value, a note or a payload: the SB-412 rule,
-- because an audit log that quietly captures personal content is worse than none.
-- reason_code is a short snake_case code for the same reason; free text would be a
-- side door for content.
--
-- user_id is the data owner and deliberately has no FK. Audit rows must survive
-- account deletion, and the delete cascade must never fail on them.

create table public.crm_audit_log (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  actor_id     uuid,
  actor_kind   text not null default 'user' check (actor_kind in ('user','agent','system')),
  action       text not null check (action in ('merge','export','bulk_import','sensitivity_change',
                                               'delete','archive','unarchive','restricted_read')),
  entity_type  text not null check (entity_type ~ '^crm_[a-z_]{1,60}$'),
  entity_id    uuid,
  entity_count integer not null default 1 check (entity_count >= 0),
  outcome      text not null default 'succeeded' check (outcome in ('succeeded','failed','denied')),
  reason_code  text check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  created_at   timestamptz not null default now()
);

comment on table public.crm_audit_log is
  'SB-462 / ADR-CRM-001. Append-only. Who did what to which CRM row, never the content. '
  'No column can hold a name, value, note or payload; reason_code is a snake_case code.';

create index crm_audit_log_user_time on public.crm_audit_log (user_id, created_at desc);
create index crm_audit_log_entity    on public.crm_audit_log (entity_id);

-- Append-only, enforced in the table and not only by withheld grants. It calls
-- nothing, so its privilege surface is empty (SB-433).
create function public.crm_audit_append_only()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  raise exception 'SB-462: crm_audit_log is append-only (% refused)', tg_op
    using errcode = '42501';
end $fn$;

create trigger trg_crm_audit_append_only
  before update or delete on public.crm_audit_log
  for each row execute function public.crm_audit_append_only();

alter table public.crm_audit_log enable row level security;
revoke all on public.crm_audit_log from public, anon, authenticated;
grant select, insert on public.crm_audit_log to authenticated;

create policy crm_audit_log_select_own on public.crm_audit_log
  for select to authenticated
  using (user_id = (select auth.uid()));

-- A client may only write rows about its own data, as itself.
create policy crm_audit_log_insert_self on public.crm_audit_log
  for insert to authenticated
  with check (user_id = (select auth.uid()) and actor_id = (select auth.uid()));

-- ---------------------------------------------------------------- crm_audit()
-- The explicit path for the actions no trigger can see: merge (SB-467), export
-- (SB-476), bulk import (SB-477) and restricted reads (SB-464). SECURITY INVOKER,
-- so a client can only write rows attributed to itself: the insert policy above
-- is the gate. A server caller (service_role, no auth.uid()) names the owner.
create function public.crm_audit(
  p_action       text,
  p_entity_type  text,
  p_entity_id    uuid    default null,
  p_entity_count integer default 1,
  p_outcome      text    default 'succeeded',
  p_reason_code  text    default null,
  p_actor_kind   text    default null,
  p_owner        uuid    default null
) returns uuid
language plpgsql security invoker set search_path = '' as $fn$
declare
  v_uid   uuid := auth.uid();
  v_owner uuid;
  v_id    uuid;
begin
  if p_action not in ('merge','export','bulk_import','restricted_read') then
    raise exception 'crm_audit: % is recorded by triggers, not by callers', p_action
      using errcode = '22023';
  end if;
  if v_uid is not null and p_owner is not null and p_owner <> v_uid then
    raise exception 'crm_audit: a signed-in caller can only audit its own data'
      using errcode = '42501';
  end if;
  v_owner := coalesce(v_uid, p_owner);
  if v_owner is null then
    raise exception 'crm_audit: no owner (pass p_owner when calling without a user session)'
      using errcode = '22023';
  end if;

  insert into public.crm_audit_log
    (user_id, actor_id, actor_kind, action, entity_type, entity_id, entity_count, outcome, reason_code)
  values
    (v_owner, v_uid,
     coalesce(p_actor_kind, case when v_uid is null then 'system' else 'user' end),
     p_action, p_entity_type, p_entity_id, coalesce(p_entity_count, 1),
     coalesce(p_outcome, 'succeeded'), p_reason_code)
  returning id into v_id;
  return v_id;
end $fn$;

revoke all on function public.crm_audit(text,text,uuid,integer,text,text,text,uuid) from public, anon;
grant execute on function public.crm_audit(text,text,uuid,integer,text,text,text,uuid) to authenticated, service_role;

-- ---------------------------------------------------------------- shared row triggers
-- Archive stamp: archived_at follows the house `archived` boolean.
create function public.crm_stamp_archive()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.archived then
    if tg_op = 'INSERT' or not old.archived then
      new.archived_at := coalesce(new.archived_at, now());
    end if;
  else
    new.archived_at := null;
  end if;
  return new;
end $fn$;

-- Row events: delete, archive/unarchive, sensitivity change.
--
-- SECURITY DEFINER, on purpose. A delete can arrive as a role that holds no grant
-- on crm_audit_log: the cascade from auth.users runs as supabase_auth_admin. An
-- invoker-rights trigger would then either block account deletion or have to
-- swallow the failure, and an audit trail that silently skips is not one. What
-- it writes is computed entirely from the row and the session (owner, id,
-- operation), so the elevated insert carries nothing a caller chose. It is a
-- trigger function, which PostgREST cannot call, and EXECUTE is revoked from the
-- client roles regardless.
create function public.crm_audit_row_event()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  v_uid  uuid := auth.uid();
  v_kind text := case when auth.uid() is null then 'system' else 'user' end;
  o jsonb;
  n jsonb;
begin
  if tg_op = 'DELETE' then
    insert into public.crm_audit_log (user_id, actor_id, actor_kind, action, entity_type, entity_id)
    values (old.user_id, v_uid, v_kind, 'delete', tg_table_name, old.id);
    return old;
  end if;

  o := to_jsonb(old);
  n := to_jsonb(new);
  if (o->'archived') is distinct from (n->'archived') then
    insert into public.crm_audit_log (user_id, actor_id, actor_kind, action, entity_type, entity_id)
    values (new.user_id, v_uid, v_kind,
            case when (n->>'archived')::boolean then 'archive' else 'unarchive' end,
            tg_table_name, new.id);
  end if;
  if n ? 'sensitivity' and (o->'sensitivity') is distinct from (n->'sensitivity') then
    insert into public.crm_audit_log (user_id, actor_id, actor_kind, action, entity_type, entity_id, reason_code)
    values (new.user_id, v_uid, v_kind, 'sensitivity_change', tg_table_name, new.id,
            (o->>'sensitivity') || '_to_' || (n->>'sensitivity'));
  end if;
  return new;
end $fn$;

revoke all on function public.crm_stamp_archive()   from public, anon, authenticated;
revoke all on function public.crm_audit_row_event() from public, anon, authenticated;
revoke all on function public.crm_audit_append_only() from public, anon, authenticated;

-- ---------------------------------------------------------------- the owned-table standard
-- Every owned CRM table gets the same four things. They are defined once here so
-- the standard cannot drift between migrations, and asserted by a second function
-- that each migration calls on its own tables before it can record:
--   1. archive stamp and updated_at (BEFORE),
--   2. audit of delete and of archive changes (AFTER, SB-462), plus sensitivity
--      changes where the table has that column (SB-464),
--   3. RLS with one owner policy per command (SB-465). TO authenticated is never
--      the whole test, and UPDATE carries WITH CHECK so a row cannot be handed to
--      another owner,
--   4. explicit grants (SB-488 removed the defaults), nothing to anon.
-- Migration-time helpers: EXECUTE is revoked from every client role.
create function public.crm_secure_owned_table(p_table regclass)
returns void language plpgsql set search_path = '' as $fn$
declare
  t text := (select relname from pg_catalog.pg_class where oid = p_table);
  audit_cols text := 'archived';
begin
  if t !~ '^crm_' then raise exception 'crm_secure_owned_table: % is not a CRM table', t; end if;
  if exists (select 1 from pg_catalog.pg_attribute where attrelid = p_table and attname = 'sensitivity' and not attisdropped) then
    audit_cols := 'archived, sensitivity';
  end if;

  execute format('create trigger trg_%s_10_archive before insert or update on public.%I
                    for each row execute function public.crm_stamp_archive()', t, t);
  execute format('create trigger trg_%s_20_updated_at before update on public.%I
                    for each row execute function public.update_updated_at()', t, t);
  execute format('create trigger trg_%s_90_audit_delete after delete on public.%I
                    for each row execute function public.crm_audit_row_event()', t, t);
  execute format('create trigger trg_%s_90_audit_change after update of %s on public.%I
                    for each row execute function public.crm_audit_row_event()', t, audit_cols, t);

  execute format('alter table public.%I enable row level security', t);
  execute format('revoke all on public.%I from public, anon, authenticated', t);
  execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  execute format('create policy %I on public.%I for select to authenticated
                    using (user_id = (select auth.uid()))', t || '_select_own', t);
  execute format('create policy %I on public.%I for insert to authenticated
                    with check (user_id = (select auth.uid()))', t || '_insert_own', t);
  execute format('create policy %I on public.%I for update to authenticated
                    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t || '_update_own', t);
  execute format('create policy %I on public.%I for delete to authenticated
                    using (user_id = (select auth.uid()))', t || '_delete_own', t);
end $fn$;

create function public.crm_assert_owned_table(p_table regclass)
returns void language plpgsql set search_path = '' as $fn$
declare
  t text := (select relname from pg_catalog.pg_class where oid = p_table);
  n int;
begin
  if not (select relrowsecurity from pg_catalog.pg_class where oid = p_table) then
    raise exception 'A1: RLS off on %', t;
  end if;
  select count(*) into n from pg_catalog.pg_policies
   where schemaname = 'public' and tablename = t and roles = '{authenticated}'
     and coalesce(qual, with_check) like '%user_id = ( SELECT auth.uid()%';
  if n <> 4 then raise exception 'A2: % has % owner policies, expected 4', t, n; end if;
  if exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = t
              and cmd = 'UPDATE' and (qual is null or with_check is null)) then
    raise exception 'A3: % UPDATE policy lacks USING or WITH CHECK', t;
  end if;
  if exists (select 1 from pg_catalog.pg_policies where schemaname = 'public' and tablename = t
              and coalesce(qual, with_check) not like '%user_id = ( SELECT auth.uid()%') then
    raise exception 'A4: % has a policy that does not test ownership', t;
  end if;
  if has_table_privilege('anon', p_table, 'select,insert,update,delete,truncate,references,trigger') then
    raise exception 'A5: anon holds a privilege on %', t;
  end if;
  if not (has_table_privilege('authenticated', p_table, 'select')
      and has_table_privilege('authenticated', p_table, 'insert')
      and has_table_privilege('authenticated', p_table, 'update')
      and has_table_privilege('authenticated', p_table, 'delete')) then
    raise exception 'A6: authenticated lacks a CRUD grant on %', t;
  end if;
  if has_table_privilege('authenticated', p_table, 'truncate') then
    raise exception 'A7: authenticated can TRUNCATE %, which bypasses RLS and the audit', t;
  end if;
  select count(*) into n from pg_catalog.pg_trigger
   where tgrelid = p_table and not tgisinternal
     and tgname in ('trg_' || t || '_10_archive', 'trg_' || t || '_20_updated_at',
                    'trg_' || t || '_90_audit_delete', 'trg_' || t || '_90_audit_change');
  if n <> 4 then raise exception 'A8: % has % of the 4 standard triggers', t, n; end if;
end $fn$;

revoke all on function public.crm_secure_owned_table(regclass) from public, anon, authenticated, service_role;
revoke all on function public.crm_assert_owned_table(regclass) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.crm_audit_log'::regclass) then
    raise exception 'A1: RLS is not enabled on crm_audit_log';
  end if;
  if has_table_privilege('anon', 'public.crm_audit_log', 'select,insert,update,delete') then
    raise exception 'A2: anon holds a privilege on crm_audit_log';
  end if;
  if has_table_privilege('authenticated', 'public.crm_audit_log', 'update')
     or has_table_privilege('authenticated', 'public.crm_audit_log', 'delete') then
    raise exception 'A3: authenticated can update or delete audit rows';
  end if;
  if has_function_privilege('anon', 'public.crm_audit(text,text,uuid,integer,text,text,text,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.crm_audit_row_event()', 'execute') then
    raise exception 'A4: a client role can execute an audit function it should not';
  end if;
  -- A5: the column set is exactly the allowed one; a new column would be a place for content.
  if (select array_agg(attname::text order by attname) from pg_attribute
       where attrelid = 'public.crm_audit_log'::regclass and attnum > 0 and not attisdropped)
     <> array['action','actor_id','actor_kind','created_at','entity_count','entity_id',
              'entity_type','id','outcome','reason_code','user_id'] then
    raise exception 'A5: crm_audit_log columns differ from the allowed set';
  end if;
end $chk$;;
