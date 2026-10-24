-- SB-600 (SB-412, ADR-API-002; found by the SB-414 re-verification 2026-10-12).
-- family-codex-mcp never wrote external_connection_audit_log, so the audit trail was
-- empty and external_connection_precheck, which counts audit rows, never limited
-- anything. Since SB-595 the OAuth client is denied the table itself, so the server
-- records through this RPC instead.
--
-- external_connection_record writes one sanitized row for the caller's own OAuth
-- session:
--   * caller = the connection's principal (auth.uid()) AND the token's client_id is
--     the connection's client. Dashboard sessions carry no client_id and are refused,
--     so nobody can forge or pad another session's trail.
--   * principal, client and connection come from the connection row, never from
--     arguments.
--   * every text argument must be an identifier ([a-z_], at most 64 characters), so
--     no title, body, prompt or token can enter the log through it. This is the same
--     structural rule as the table, which has no content column.

create or replace function public.external_connection_record(
  p_connection_id uuid,
  p_tool_name     text,
  p_operation     text,
  p_outcome       text,
  p_reason_code   text default null,
  p_resource_name text default null,
  p_project_id    uuid default null,
  p_result_rows   integer default null,
  p_trace_id      uuid default null
) returns uuid
language plpgsql volatile security definer set search_path = '' as $fn$
declare
  c    public.external_connections%rowtype;
  v_id uuid;
begin
  if p_tool_name is null or p_tool_name !~ '^[a-z_]{1,64}$' then
    raise exception 'SB-600: tool_name must be an identifier' using errcode = '22023';
  end if;
  if p_operation is null or p_operation not in ('read', 'write') then
    raise exception 'SB-600: operation must be read or write' using errcode = '22023';
  end if;
  if p_outcome is null or p_outcome not in ('allowed', 'denied', 'error') then
    raise exception 'SB-600: outcome must be allowed, denied or error' using errcode = '22023';
  end if;
  if p_reason_code is not null and p_reason_code !~ '^[a-z_]{1,64}$' then
    raise exception 'SB-600: reason_code must be an identifier' using errcode = '22023';
  end if;
  if p_resource_name is not null and p_resource_name !~ '^[a-z_]{1,64}$' then
    raise exception 'SB-600: resource_name must be an identifier' using errcode = '22023';
  end if;
  if p_result_rows is not null and (p_result_rows < 0 or p_result_rows > 1000) then
    raise exception 'SB-600: result_rows out of range' using errcode = '22023';
  end if;

  select * into c from public.external_connections where id = p_connection_id;
  if not found
     or auth.uid() is null
     or c.principal_user_id is distinct from auth.uid()
     or public.oauth_client_id() is null
     or c.oauth_client_id is distinct from public.oauth_client_id() then
    raise exception 'SB-600: only the connection''s own OAuth session may record its calls' using errcode = '42501';
  end if;

  insert into public.external_connection_audit_log
    (connection_id, principal_user_id, oauth_client_id, tool_name, resource_name, operation,
     project_id, outcome, reason_code, trace_id, result_rows)
  values (c.id, c.principal_user_id, c.oauth_client_id, p_tool_name, p_resource_name, p_operation,
          p_project_id, p_outcome, p_reason_code, p_trace_id, p_result_rows)
  returning id into v_id;

  return v_id;
end $fn$;

comment on function public.external_connection_record(uuid, text, text, text, text, text, uuid, integer, uuid) is
  'SB-600: the OAuth client''s only write path into external_connection_audit_log. Caller must be the connection''s principal on its own client; text arguments are identifiers only.';

revoke all on function public.external_connection_record(uuid, text, text, text, text, text, uuid, integer, uuid) from public, anon, authenticated;
grant execute on function public.external_connection_record(uuid, text, text, text, text, text, uuid, integer, uuid) to authenticated, service_role;

-- assertions
do $$
begin
  if not exists (
    select 1 from pg_proc p
     where p.oid = 'public.external_connection_record(uuid, text, text, text, text, text, uuid, integer, uuid)'::regprocedure
       and p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 'v'
       and has_function_privilege('authenticated', p.oid, 'execute')
       and not has_function_privilege('anon', p.oid, 'execute')
       and not has_function_privilege('public', p.oid, 'execute')) then
    raise exception 'SB-600: external_connection_record posture is wrong';
  end if;
  if not exists (select 1 from pg_policy where polrelid = 'public.external_connection_audit_log'::regclass and polname = 'oauth_client_deny') then
    raise exception 'SB-600: expected SB-595 to deny the OAuth client the audit table directly';
  end if;
end $$;
