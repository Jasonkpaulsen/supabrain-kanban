-- External connection record suite: TC-SB600-1..5 (SB-600; SB-412, ADR-API-002).
--
-- Run as postgres. One transaction that always ends by raising, so no audit row, limit or
-- fixture it writes survives. Acts as the connection's principal on its registered client,
-- as other sessions that must be refused, and as postgres to read results.
-- Pass = the raised message starts with "EXT-CONN-RECORD PASS". Counts and sqlstates only.

do $suite$
declare
  ub    constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner (creates connections)
  mandy constant uuid := '0dd94a9f-1890-48b0-9e4f-a4bbfff949f0';   -- principal
  rb    constant text := '__sb600_rollback__';
  r jsonb := '{}'::jsonb;
  conn uuid; cid text; other uuid; foreign_conn uuid; trace uuid := gen_random_uuid();
  n int; m int; k int; fails int; st text; msg text; v uuid; v2 uuid;
  a public.external_connection_audit_log%rowtype;
  pc record;
begin
  select id, oauth_client_id into conn, cid from public.external_connections
   where principal_user_id = mandy and status = 'active' limit 1;
  if conn is null then raise exception 'EXT-CONN-RECORD FAIL: no active connection for the principal'; end if;
  select u.id into other from auth.users u where u.id not in (ub, mandy) order by u.created_at limit 1;

  -- ------------------------------------------------ TC-SB600-1: the principal's own OAuth session records
  begin
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      v  := public.external_connection_record(conn, 'list_family_records', 'read', 'allowed', null, 'medication', null, 7, trace);
      v2 := public.external_connection_record(conn, 'create_work_item', 'write', 'denied', 'confirmation_required', null, null, null, trace);
      reset role;
      select count(*) into n from public.external_connection_audit_log where id in (v, v2);
      select * into a from public.external_connection_audit_log where id = v;
      select count(*) into m from public.external_connection_audit_log
       where id = v2 and outcome = 'denied' and operation = 'write' and reason_code = 'confirmation_required' and tool_name = 'create_work_item';
      r := r || jsonb_build_object('TC-SB600-1', case
             when n = 2 and m = 1 and a.connection_id = conn and a.principal_user_id = mandy and a.oauth_client_id = cid
              and a.tool_name = 'list_family_records' and a.operation = 'read' and a.outcome = 'allowed'
              and a.resource_name = 'medication' and a.result_rows = 7 and a.trace_id = trace and a.created_at is not null
             then 'pass' else format('FAIL: rows %s, denied row ok %s, read row principal_ok %s client_ok %s', n, m, a.principal_user_id = mandy, a.oauth_client_id = cid) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB600-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB600-2: nobody else can write audit rows
  begin
    begin
      reset role;
      select count(*) into n from public.external_connection_audit_log;
      insert into public.external_connections (name, principal_user_id, oauth_client_id, status, created_by)
        values ('qa-sb600 foreign connection', ub, 'qa-sb600-client', 'active', ub) returning id into foreign_conn;
      k := 0; msg := '';
      -- (a) anon, (b) owner direct, (c) principal direct, (d) principal wrong client, (e) other user right client, (f) principal on a connection that is not hers
      for i in 1..6 loop
        st := 'no error';
        begin
          if i = 1 then perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'anon', 'client_id', cid)::text, true); set local role anon;
          elsif i = 2 then perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true); set local role authenticated;
          elsif i = 3 then perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated')::text, true); set local role authenticated;
          elsif i = 4 then perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', 'qa-wrong-client')::text, true); set local role authenticated;
          elsif i = 5 then perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated', 'client_id', cid)::text, true); set local role authenticated;
          else perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true); set local role authenticated;
          end if;
          perform public.external_connection_record(case when i = 6 then foreign_conn else conn end, 'list_work_items', 'read', 'allowed');
        exception when others then
          st := sqlstate;
        end;
        reset role;
        if st = '42501' then k := k + 1; else msg := msg || format('[case %s: %s] ', i, st); end if;
      end loop;
      select count(*) into m from public.external_connection_audit_log;
      r := r || jsonb_build_object('TC-SB600-2', case when k = 6 and m = n then 'pass'
             else format('FAIL: refused %s of 6 %s; rows %s->%s', k, msg, n, m) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB600-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB600-3: no content through the RPC
  begin
    begin
      reset role;
      select count(*) into n from public.external_connection_audit_log;
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      k := 0; msg := '';
      for i in 1..8 loop
        st := 'no error';
        begin
          case i
            when 1 then perform public.external_connection_record(conn, 'list work items', 'read', 'allowed');
            when 2 then perform public.external_connection_record(conn, repeat('a', 65), 'read', 'allowed');
            when 3 then perform public.external_connection_record(conn, 'list_work_items', 'read', 'denied', 'the database refused this request');
            when 4 then perform public.external_connection_record(conn, 'list_work_items', 'read', 'allowed', null, 'medications;');
            when 5 then perform public.external_connection_record(conn, 'list_work_items', 'remove', 'allowed');
            when 6 then perform public.external_connection_record(conn, 'list_work_items', 'read', 'ok');
            when 7 then perform public.external_connection_record(conn, 'list_work_items', 'read', 'allowed', null, null, null, -1);
            else        perform public.external_connection_record(conn, 'list_work_items', 'read', 'allowed', null, null, null, 100000);
          end case;
        exception when others then
          st := sqlstate;
        end;
        if st = '22023' then k := k + 1; else msg := msg || format('[case %s: %s] ', i, st); end if;
      end loop;
      reset role;
      select count(*) into m from public.external_connection_audit_log;
      r := r || jsonb_build_object('TC-SB600-3', case when k = 8 and m = n then 'pass'
             else format('FAIL: refused %s of 8 %s; rows %s->%s', k, msg, n, m) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB600-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB600-4: recorded rows drive the rate limit
  begin
    begin
      reset role;
      insert into public.external_connection_limits (connection_id, tool_name, max_calls, window_seconds, max_rows)
        values (conn, null, 3, 3600, null);
      perform set_config('request.jwt.claims', json_build_object('sub', mandy, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      k := 0;
      for i in 1..3 loop
        select * into pc from public.external_connection_precheck(conn, 'list_work_items');
        if pc.allowed then k := k + 1; end if;
        perform public.external_connection_record(conn, 'list_work_items', 'read', 'allowed');
      end loop;
      select * into pc from public.external_connection_precheck(conn, 'list_work_items');
      reset role;
      r := r || jsonb_build_object('TC-SB600-4', case
             when k = 3 and not pc.allowed and pc.reason_code = 'rate_limited' and pc.retry_after_seconds > 0 then 'pass'
             else format('FAIL: allowed before limit %s of 3; after: allowed %s reason %s retry %s', k, pc.allowed, pc.reason_code, pc.retry_after_seconds) end);
      r := r || jsonb_build_object('TC-SB600-4.evidence', format('3 allowed, then %s with retry_after %s s', pc.reason_code, pc.retry_after_seconds));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB600-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB600-5: posture
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.external_connection_record(uuid, text, text, text, text, text, uuid, integer, uuid)'::regprocedure
       and p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 'v'
       and has_function_privilege('authenticated', p.oid, 'execute')
       and has_function_privilege('service_role', p.oid, 'execute')
       and not has_function_privilege('anon', p.oid, 'execute')
       and not has_function_privilege('public', p.oid, 'execute');
    r := r || jsonb_build_object('TC-SB600-5', case when n = 1 then 'pass' else 'FAIL: posture' end);
  exception when others then
    r := r || jsonb_build_object('TC-SB600-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  reset role;
  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'EXT-CONN-RECORD PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'EXT-CONN-RECORD FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
