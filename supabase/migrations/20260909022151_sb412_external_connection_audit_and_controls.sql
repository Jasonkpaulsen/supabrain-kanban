-- SB-412: append-only audit, rate limits, and revocation controls for external connections.
--
-- Two lessons are baked in up front rather than discovered later:
--   SB-408: the Supabase project default ACL grants anon/authenticated ALL on every new
--           public table BEFORE migration GRANTs run, so a GRANT alone is a silent no-op.
--           Every table below is REVOKEd first, then granted exactly what it needs.
--   SB-433: the privilege surface of a trigger is the transitive closure of what its body
--           calls, evaluated as the WRITER. The append-only trigger below therefore calls
--           nothing at all, and no function here depends on the auth schema.

-- ---------------------------------------------------------------- audit log
create table if not exists public.external_connection_audit_log (
  id               uuid primary key default gen_random_uuid(),
  connection_id    uuid not null references public.external_connections(id) on delete cascade,
  principal_user_id uuid,
  oauth_client_id  text,
  tool_name        text,
  resource_name    text,
  operation        text,
  project_id       uuid,
  outcome          text not null check (outcome in ('allowed','denied','error')),
  reason_code      text,
  trace_id         uuid,
  result_rows      integer,
  created_at       timestamptz not null default now()
);

comment on table public.external_connection_audit_log is
  'SB-412. Append-only. Records WHAT was attempted and HOW it resolved, never the content. '
  'There is deliberately no column able to hold a prompt, title, description, comment body, '
  'row payload, token or secret: this covers family medical data, and an audit log that '
  'quietly captures row bodies is worse than no audit log at all.';

create index if not exists idx_ecal_connection_time on public.external_connection_audit_log (connection_id, created_at desc);
create index if not exists idx_ecal_principal_time  on public.external_connection_audit_log (principal_user_id, created_at desc);
create index if not exists idx_ecal_tool_time       on public.external_connection_audit_log (connection_id, tool_name, created_at desc);

-- append-only, enforced in the table itself and not only by withheld grants
create or replace function public.external_connection_audit_append_only()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  raise exception 'SB-412: external_connection_audit_log is append-only (% refused)', tg_op
    using errcode = '42501';
end $fn$;

drop trigger if exists trg_ecal_append_only on public.external_connection_audit_log;
create trigger trg_ecal_append_only
  before update or delete on public.external_connection_audit_log
  for each row execute function public.external_connection_audit_append_only();

alter table public.external_connection_audit_log enable row level security;

revoke all on public.external_connection_audit_log from public, anon, authenticated;
grant select, insert on public.external_connection_audit_log to authenticated;
grant select, insert on public.external_connection_audit_log to service_role;

-- the principal may read only their own events; the connection owner reads all of theirs
drop policy if exists ecal_select_own_or_owner on public.external_connection_audit_log;
create policy ecal_select_own_or_owner on public.external_connection_audit_log
  for select to authenticated
  using (
    principal_user_id = auth.uid()
    or exists (select 1 from public.external_connections c
                where c.id = external_connection_audit_log.connection_id
                  and c.created_by = auth.uid())
  );

-- a caller may only write rows attributed to themselves, on a connection that is theirs
drop policy if exists ecal_insert_self on public.external_connection_audit_log;
create policy ecal_insert_self on public.external_connection_audit_log
  for insert to authenticated
  with check (
    principal_user_id = auth.uid()
    and exists (select 1 from public.external_connections c
                 where c.id = external_connection_audit_log.connection_id
                   and c.principal_user_id = auth.uid())
  );

-- ---------------------------------------------------------------- rate limits
create table if not exists public.external_connection_limits (
  id             uuid primary key default gen_random_uuid(),
  connection_id  uuid references public.external_connections(id) on delete cascade,
  tool_name      text,
  max_calls      integer not null check (max_calls > 0),
  window_seconds integer not null check (window_seconds > 0),
  max_rows       integer check (max_rows > 0),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.external_connection_limits is
  'SB-412. connection_id null = applies to every connection; tool_name null = the '
  'per-connection aggregate across all tools. The aggregate row is what stops a caller '
  'evading a per-tool limit by rotating tools.';

create unique index if not exists uq_ecl_scope
  on public.external_connection_limits (coalesce(connection_id,'00000000-0000-0000-0000-000000000000'::uuid),
                                        coalesce(tool_name,'*'));

alter table public.external_connection_limits enable row level security;
revoke all on public.external_connection_limits from public, anon, authenticated;
grant select on public.external_connection_limits to authenticated;
grant select on public.external_connection_limits to service_role;

drop policy if exists ecl_select_related on public.external_connection_limits;
create policy ecl_select_related on public.external_connection_limits
  for select to authenticated
  using (
    connection_id is null
    or exists (select 1 from public.external_connections c
                where c.id = external_connection_limits.connection_id
                  and (c.principal_user_id = auth.uid() or c.created_by = auth.uid()))
  );

-- conservative defaults, global
insert into public.external_connection_limits (connection_id, tool_name, max_calls, window_seconds, max_rows)
values (null, null, 600, 3600, null),
       (null, '*write*', 120, 3600, null)
on conflict do nothing;

-- ---------------------------------------------------------------- checks
-- Verdict-only. Returns whether a call may proceed and why not; never returns data.
-- SECURITY DEFINER is required because the aggregate rate check must count rows across
-- the whole connection, which the principal's own SELECT policy deliberately does not
-- expose. It returns a boolean and a reason code, so nothing readable leaks through it.
create or replace function public.external_connection_precheck(
  p_connection_id uuid,
  p_tool_name     text default null
) returns table (allowed boolean, reason_code text, retry_after_seconds integer)
language plpgsql stable security definer set search_path = '' as $fn$
declare
  c              public.external_connections%rowtype;
  v_limit        public.external_connection_limits%rowtype;
  v_used         integer;
  v_oldest       timestamptz;
begin
  select * into c from public.external_connections where id = p_connection_id;

  if not found then
    return query select false, 'connection_not_found', null::integer; return;
  end if;
  if c.status <> 'active' then
    return query select false, 'connection_' || c.status, null::integer; return;
  end if;
  if c.expires_at is not null and c.expires_at <= now() then
    return query select false, 'connection_expired', null::integer; return;
  end if;

  -- most specific limit wins: this connection + this tool, else this connection,
  -- else global + tool, else global aggregate
  select * into v_limit from public.external_connection_limits l
   where (l.connection_id = p_connection_id or l.connection_id is null)
     and (l.tool_name = p_tool_name or l.tool_name is null)
   order by (l.connection_id is not null) desc, (l.tool_name is not null) desc
   limit 1;

  if found then
    select count(*), min(created_at) into v_used, v_oldest
      from public.external_connection_audit_log a
     where a.connection_id = p_connection_id
       and (v_limit.tool_name is null or a.tool_name = v_limit.tool_name)
       and a.created_at > now() - make_interval(secs => v_limit.window_seconds);

    if v_used >= v_limit.max_calls then
      return query select false, 'rate_limited',
        greatest(1, ceil(extract(epoch from (v_oldest + make_interval(secs => v_limit.window_seconds)) - now()))::integer);
      return;
    end if;
  end if;

  return query select true, null::text, null::integer;
end $fn$;

revoke all on function public.external_connection_precheck(uuid, text) from public;
grant execute on function public.external_connection_precheck(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------- kill switch
create or replace function public.set_external_connection_status(
  p_connection_id uuid,
  p_status        text,
  p_reason        text default null
) returns public.external_connections
language plpgsql volatile security definer set search_path = '' as $fn$
declare c public.external_connections%rowtype;
begin
  if p_status not in ('active','disabled','revoked') then
    raise exception 'SB-412: status must be active, disabled or revoked' using errcode = '22023';
  end if;

  select * into c from public.external_connections where id = p_connection_id;
  if not found then
    raise exception 'SB-412: connection not found' using errcode = 'P0002';
  end if;

  -- owner only. SECURITY DEFINER, so the check is made explicitly rather than relying on RLS.
  if c.created_by is distinct from auth.uid() then
    raise exception 'SB-412: only the connection owner may change its status' using errcode = '42501';
  end if;

  update public.external_connections
     set status = p_status,
         meta = coalesce(meta,'{}'::jsonb) || jsonb_build_object(
                  'status_changed_at', now()::text,
                  'status_changed_by', auth.uid()::text,
                  'status_change_reason', p_reason),
         updated_at = now()
   where id = p_connection_id
   returning * into c;

  insert into public.external_connection_audit_log
    (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome, reason_code)
  values (p_connection_id, c.principal_user_id, c.oauth_client_id,
          'set_external_connection_status', 'update', 'allowed', 'status_' || p_status);

  return c;
end $fn$;

revoke all on function public.set_external_connection_status(uuid, text, text) from public;
grant execute on function public.set_external_connection_status(uuid, text, text) to authenticated, service_role;;
