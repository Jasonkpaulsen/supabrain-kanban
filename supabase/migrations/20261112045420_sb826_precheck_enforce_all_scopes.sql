-- SB-826 D1: enforce every applicable limit scope; '*write*' = all write tools, per principal.
-- Same signature, return type, owner and grants as before (CREATE OR REPLACE keeps grants).
CREATE OR REPLACE FUNCTION public.external_connection_precheck(p_connection_id uuid, p_tool_name text DEFAULT NULL::text)
 RETURNS TABLE(allowed boolean, reason_code text, retry_after_seconds integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c          public.external_connections%rowtype;
  v_limit    public.external_connection_limits%rowtype;
  -- Read tools are exactly list_* / get_*; anything else (NULL, unknown) counts as a write.
  -- Kept in step with readOnlyHint in family-codex-mcp by unit test U-826-1.
  v_is_write boolean := coalesce(p_tool_name !~ '^(list|get)_[a-z_]+$', true);
  v_used     integer;
  v_edge     timestamptz;
  v_retry    integer := null;
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

  -- SB-826: every applicable scope is enforced, not only the most specific one.
  --   aggregate  tool_name IS NULL        calls on this connection
  --   class      tool_name = '*write*'    write attempts by this principal, any connection
  --   exact      tool_name = p_tool_name  calls to this tool on this connection
  -- Within a scope a connection-specific row overrides the global row.
  for v_limit in
    select distinct on (coalesce(l.tool_name, '*')) l.*
      from public.external_connection_limits l
     where (l.connection_id = p_connection_id or l.connection_id is null)
       and (l.tool_name is null
            or l.tool_name = p_tool_name
            or (l.tool_name = '*write*' and v_is_write))
     order by coalesce(l.tool_name, '*'), (l.connection_id is not null) desc
  loop
    v_edge := null;
    if v_limit.tool_name = '*write*' then
      select count(*) into v_used
        from public.external_connection_audit_log a
       where a.principal_user_id = c.principal_user_id
         and a.operation = 'write'
         and a.reason_code is distinct from 'rate_limited'
         and a.created_at > now() - make_interval(secs => v_limit.window_seconds);
      if v_used >= v_limit.max_calls then
        select a.created_at into v_edge
          from public.external_connection_audit_log a
         where a.principal_user_id = c.principal_user_id
           and a.operation = 'write'
           and a.reason_code is distinct from 'rate_limited'
           and a.created_at > now() - make_interval(secs => v_limit.window_seconds)
         order by a.created_at asc
         offset (v_used - v_limit.max_calls) limit 1;
      end if;
    else
      select count(*) into v_used
        from public.external_connection_audit_log a
       where a.connection_id = p_connection_id
         and a.operation in ('read', 'write')
         and a.reason_code is distinct from 'rate_limited'
         and (v_limit.tool_name is null or a.tool_name = v_limit.tool_name)
         and a.created_at > now() - make_interval(secs => v_limit.window_seconds);
      if v_used >= v_limit.max_calls then
        select a.created_at into v_edge
          from public.external_connection_audit_log a
         where a.connection_id = p_connection_id
           and a.operation in ('read', 'write')
           and a.reason_code is distinct from 'rate_limited'
           and (v_limit.tool_name is null or a.tool_name = v_limit.tool_name)
           and a.created_at > now() - make_interval(secs => v_limit.window_seconds)
         order by a.created_at asc
         offset (v_used - v_limit.max_calls) limit 1;
      end if;
    end if;

    if v_edge is not null then
      v_retry := greatest(coalesce(v_retry, 1),
        greatest(1, ceil(extract(epoch from (v_edge + make_interval(secs => v_limit.window_seconds)) - now()))::integer));
    end if;
  end loop;

  if v_retry is not null then
    return query select false, 'rate_limited', v_retry; return;
  end if;
  return query select true, null::text, null::integer;
end $function$;
