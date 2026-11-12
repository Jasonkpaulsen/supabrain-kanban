-- External connection limits + identity-refusal audit suite: TC-SB826-F1..F8, TC-SB827-F1..F10
-- (SB-826 D1 sb826_precheck_enforce_all_scopes, SB-827 D2 sb827_auth_refusal_audit).
--
-- Run as postgres, AFTER both migrations are applied. One transaction that always ends by
-- raising, and every case also rolls itself back, so no audit row, limit or fixture it writes
-- survives (the audit log is append-only: nothing here could be cleaned up any other way).
-- Same raise-at-end pattern as external_connection_record_suite.sql.
--
-- The connection, its principal and its client are looked up from the one active connection;
-- other users are looked up from auth.users. Nothing is hard-coded and no family content is
-- read or written: fixtures are synthetic audit rows and 'qa-sb82x-*' connections.
-- Pass = the raised message starts with "EXT-CONN-LIMITS PASS". Counts and sqlstates only.
--
-- Baselines: live rows already inside a window are counted first and the fixtures top up to
-- the cap, so the suite stays exact whatever the live traffic. The SB-827 throttle cases need
-- a quiet minute (no identity refusals in the last 60 s); if one is busy it says so — rerun.

do $suite$
declare
  rb     constant text := '__sb826_827_rollback__';
  k_write constant text[] := array['create_work_item','update_work_item','add_work_item_comment','set_work_item_labels',
    'create_family_record','update_family_record','start_family_agent_session','delegate_family_agent_session',
    'complete_family_agent_session','assign_family_agent_to_work_item'];
  k_token_only constant text[] := array['token_missing','token_malformed','token_bad_signature','token_expired',
    'token_not_yet_valid','token_wrong_issuer','token_wrong_audience','token_invalid','token_no_subject'];
  r jsonb := '{}'::jsonb;
  conn uuid; cid text; principal uuid; creator uuid; conn2 uuid; fx uuid; fx2 uuid; other uuid;
  users uuid[];
  b_write int; b_agg int; b_anon int; b_global int;
  n int; m int; k int; j int; fails int; st text; msg text; trace uuid; u uuid;
  pc record; pr record; pw record; pr2 record; pw2 record;
  a public.external_connection_audit_log%rowtype;
begin
  select c.id, c.oauth_client_id, c.principal_user_id, c.created_by into conn, cid, principal, creator
    from public.external_connections c where c.status = 'active' order by c.created_at limit 1;
  if conn is null then raise exception 'EXT-CONN-LIMITS FAIL: no active connection'; end if;
  select u2.id into other from auth.users u2 where u2.id <> principal order by u2.created_at limit 1;
  select array_agg(id order by created_at) into users from (select id, created_at from auth.users order by created_at limit 3) t;

  -- Live rows already inside the windows the precheck uses.
  select count(*) into b_write from public.external_connection_audit_log x
   where x.principal_user_id = principal and x.operation = 'write'
     and x.reason_code is distinct from 'rate_limited' and x.created_at > now() - interval '3600 seconds';
  select count(*) into b_agg from public.external_connection_audit_log x
   where x.connection_id = conn and x.operation in ('read','write')
     and x.reason_code is distinct from 'rate_limited' and x.created_at > now() - interval '3600 seconds';
  select count(*) into b_anon from public.external_connection_audit_log x
   where x.connection_id is null and x.principal_user_id is null and x.created_at > now() - interval '60 seconds';
  select count(*) into b_global from public.external_connection_audit_log x
   where x.connection_id is null and x.created_at > now() - interval '60 seconds';
  r := r || jsonb_build_object('baseline.evidence', format('writes/h %s, calls/h %s, anon/min %s, connection-less/min %s', b_write, b_agg, b_anon, b_global));
  if b_write >= 119 or b_agg >= 599 then
    raise exception 'EXT-CONN-LIMITS FAIL: live usage already at the cap (writes %, calls %); rerun later', b_write, b_agg;
  end if;

  -- ================================================================ SB-826 (D1)

  -- TC-SB826-F1: 120 writes in the hour -> write refused with retry in [1, 3600]; reads still allowed
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn, principal, cid, 'create_work_item', 'write', 'allowed' from generate_series(1, 120 - b_write);
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      select * into pr from public.external_connection_precheck(conn, 'list_work_items');
      r := r || jsonb_build_object('TC-SB826-F1', case
             when not pw.allowed and pw.reason_code = 'rate_limited' and pw.retry_after_seconds between 1 and 3600 and pr.allowed
             then 'pass' else format('FAIL: write %s/%s/%s read %s', pw.allowed, pw.reason_code, pw.retry_after_seconds, pr.allowed) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F2: rotate tools — 120 writes spread over the 10 write tools -> every write tool refused
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn, principal, cid, k_write[1 + (i % 10)], 'write', 'allowed' from generate_series(1, 120 - b_write) i;
      k := 0;
      foreach st in array k_write loop
        select * into pw from public.external_connection_precheck(conn, st);
        if not pw.allowed and pw.reason_code = 'rate_limited' then k := k + 1; end if;
      end loop;
      select * into pr from public.external_connection_precheck(conn, 'get_work_item');
      r := r || jsonb_build_object('TC-SB826-F2', case when k = 10 and pr.allowed then 'pass'
             else format('FAIL: %s of 10 write tools refused; read allowed %s', k, pr.allowed) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F3: reconnect — writes split across the active connection and a second (disabled)
  -- connection of the same principal -> still refused on the active one
  begin
    begin
      insert into public.external_connections (name, principal_user_id, oauth_client_id, status, created_by)
        values ('qa-sb826 second connection', principal, 'qa-sb826-' || gen_random_uuid(), 'disabled', creator) returning id into conn2;
      n := (120 - b_write) / 2;
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn2, principal, null, 'create_work_item', 'write', 'allowed' from generate_series(1, n);
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn, principal, cid, 'update_work_item', 'write', 'allowed' from generate_series(1, 120 - b_write - n);
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      r := r || jsonb_build_object('TC-SB826-F3', case when not pw.allowed and pw.reason_code = 'rate_limited' and n >= 59
             then 'pass' else format('FAIL: allowed %s reason %s (rows on second connection %s)', pw.allowed, pw.reason_code, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F4: window reset — 120 writes backdated 3,601 s -> allowed
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome, created_at)
        select conn, principal, cid, 'create_work_item', 'write', 'allowed', now() - interval '3601 seconds' from generate_series(1, 120);
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      r := r || jsonb_build_object('TC-SB826-F4', case when pw.allowed then 'pass'
             else format('FAIL: allowed %s reason %s', pw.allowed, pw.reason_code) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F5: refusals don't count — 119 counted + 50 rate_limited -> allowed; one more counted -> refused
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn, principal, cid, 'create_work_item', 'write', 'allowed' from generate_series(1, 119 - b_write);
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome, reason_code)
        select conn, principal, cid, 'create_work_item', 'write', 'denied', 'rate_limited' from generate_series(1, 50);
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      -- a tool-level denial (confirmation_required) is a counted write attempt
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome, reason_code)
        values (conn, principal, cid, 'create_work_item', 'write', 'denied', 'confirmation_required');
      select * into pw2 from public.external_connection_precheck(conn, 'create_work_item');
      r := r || jsonb_build_object('TC-SB826-F5', case when pw.allowed and not pw2.allowed and pw2.reason_code = 'rate_limited'
             then 'pass' else format('FAIL: at 119 allowed %s; at 120 allowed %s', pw.allowed, pw2.allowed) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F6: aggregate intact — 599 calls allowed, 600 refused (reads)
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        select conn, principal, cid, 'list_work_items', 'read', 'allowed' from generate_series(1, 599 - b_agg);
      select * into pr from public.external_connection_precheck(conn, 'list_work_items');
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome)
        values (conn, principal, cid, 'list_work_items', 'read', 'allowed');
      select * into pr2 from public.external_connection_precheck(conn, 'list_work_items');
      r := r || jsonb_build_object('TC-SB826-F6', case when pr.allowed and not pr2.allowed and pr2.reason_code = 'rate_limited'
             then 'pass' else format('FAIL: at 599 allowed %s; at 600 allowed %s', pr.allowed, pr2.allowed) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F7: retry-after — 121 writes one second apart from now()-3000 s -> retry = 2nd oldest + 3600 - now = 602 s
  -- (exact when there is no live write in the hour; otherwise only the range is checked and the value recorded)
  begin
    begin
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, tool_name, operation, outcome, created_at)
        select conn, principal, cid, 'create_work_item', 'write', 'allowed', now() - interval '3000 seconds' + make_interval(secs => i)
          from generate_series(1, 121) i;
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      r := r || jsonb_build_object('TC-SB826-F7', case
             when b_write = 0 and not pw.allowed and pw.retry_after_seconds between 601 and 603 then 'pass'
             when b_write > 0 and not pw.allowed and pw.retry_after_seconds between 1 and 3600 then 'pass'
             else format('FAIL: allowed %s retry %s (expected 602 +/- 1, live writes %s)', pw.allowed, pw.retry_after_seconds, b_write) end);
      r := r || jsonb_build_object('TC-SB826-F7.evidence', format('retry_after %s s with %s live writes in the hour', pw.retry_after_seconds, b_write));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB826-F7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB826-F8: grants unchanged
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.external_connection_precheck(uuid, text)'::regprocedure
       and p.prosecdef and p.proconfig @> array['search_path=""']
       and has_function_privilege('authenticated', p.oid, 'execute')
       and has_function_privilege('service_role', p.oid, 'execute')
       and not has_function_privilege('anon', p.oid, 'execute');
    r := r || jsonb_build_object('TC-SB826-F8', case when n = 1 then 'pass' else 'FAIL: precheck posture' end);
  exception when others then
    r := r || jsonb_build_object('TC-SB826-F8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ================================================================ SB-827 (D2)

  -- TC-SB827-F1: anon, each token_* reason -> exactly one row, nothing attributed
  begin
    begin
      reset role;
      if b_anon + 9 > 10 or b_global + 9 > 30 then raise exception 'busy: % anon / % connection-less rows in the last minute; rerun', b_anon, b_global; end if;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
      set local role anon;
      foreach st in array k_token_only loop
        perform public.external_connection_record_auth_refusal(st, trace);
      end loop;
      reset role;
      select count(*), count(distinct reason_code) into n, m from public.external_connection_audit_log x where x.trace_id = trace;
      select count(*) into k from public.external_connection_audit_log x
       where x.trace_id = trace and x.connection_id is null and x.principal_user_id is null and x.oauth_client_id is null
         and x.operation = 'auth' and x.outcome = 'denied' and x.reason_code = any (k_token_only)
         and x.tool_name is null and x.resource_name is null and x.project_id is null and x.result_rows is null;
      r := r || jsonb_build_object('TC-SB827-F1', case when n = 9 and m = 9 and k = 9 then 'pass'
             else format('FAIL: rows %s distinct reasons %s well-formed %s', n, m, k) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F2: anon cannot claim identity reasons (42501); unknown / marker / null reasons are 22023; no rows
  begin
    begin
      reset role;
      select count(*) into n from public.external_connection_audit_log;
      perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
      set local role anon;
      k := 0; msg := '';
      for i in 1..5 loop
        st := 'no error';
        begin
          case i
            when 1 then perform public.external_connection_record_auth_refusal('connection_revoked');
            when 2 then perform public.external_connection_record_auth_refusal('client_id_missing');
            when 3 then perform public.external_connection_record_auth_refusal('not_a_reason');
            when 4 then perform public.external_connection_record_auth_refusal('auth_refusals_throttled');
            else        perform public.external_connection_record_auth_refusal(null);
          end case;
        exception when others then
          st := sqlstate;
        end;
        if (i <= 2 and st = '42501') or (i > 2 and st = '22023') then k := k + 1; else msg := msg || format('[case %s: %s] ', i, st); end if;
      end loop;
      reset role;
      select count(*) into m from public.external_connection_audit_log;
      r := r || jsonb_build_object('TC-SB827-F2', case when k = 5 and m = n then 'pass'
             else format('FAIL: %s of 5 refused as expected %s; rows %s->%s', k, msg, n, m) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F3: verified session without client_id -> client_id_missing (re-derived), principal set;
  -- identity_check_error -> outcome error
  begin
    begin
      reset role;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated')::text, true);
      set local role authenticated;
      perform public.external_connection_record_auth_refusal('client_id_missing', trace);
      perform public.external_connection_record_auth_refusal('connection_not_found', trace);   -- edge hint, DB re-derives
      perform public.external_connection_record_auth_refusal('identity_check_error', trace);
      reset role;
      select count(*) into n from public.external_connection_audit_log x
       where x.trace_id = trace and x.reason_code = 'client_id_missing' and x.outcome = 'denied'
         and x.principal_user_id = principal and x.connection_id is null and x.oauth_client_id is null and x.operation = 'auth';
      select count(*) into m from public.external_connection_audit_log x
       where x.trace_id = trace and x.reason_code = 'identity_check_error' and x.outcome = 'error' and x.principal_user_id = principal;
      r := r || jsonb_build_object('TC-SB827-F3', case when n = 2 and m = 1 then 'pass'
             else format('FAIL: client_id_missing rows %s of 2, identity_check_error rows %s of 1', n, m) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F4: unknown client -> connection_not_found; other user on the connection's client ->
  -- connection_principal_mismatch (connection NULL); fixture revoked / expired connections -> their reason and id
  begin
    begin
      reset role;
      if other is null then raise exception 'needs a second auth user'; end if;
      insert into public.external_connections (name, principal_user_id, oauth_client_id, status, created_by)
        values ('qa-sb827 revoked connection', principal, 'qa-sb827-r-' || gen_random_uuid(), 'revoked', creator) returning id into fx;
      insert into public.external_connections (name, principal_user_id, oauth_client_id, status, created_by, expires_at)
        values ('qa-sb827 expired connection', principal, 'qa-sb827-e-' || gen_random_uuid(), 'active', creator, now() - interval '1 day') returning id into fx2;
      k := 0; msg := '';
      for i in 1..4 loop
        trace := gen_random_uuid();   -- one trace per case: every row in this transaction shares created_at
        if i = 1 then
          perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated', 'client_id', 'qa-sb827-unknown-client')::text, true);
        elsif i = 2 then
          perform set_config('request.jwt.claims', json_build_object('sub', other, 'role', 'authenticated', 'client_id', cid)::text, true);
        elsif i = 3 then
          perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated',
            'client_id', (select oauth_client_id from public.external_connections where id = fx))::text, true);
        else
          perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated',
            'client_id', (select oauth_client_id from public.external_connections where id = fx2))::text, true);
        end if;
        set local role authenticated;
        perform public.external_connection_record_auth_refusal('connection_not_found', trace);   -- edge hint for all four
        reset role;
        select * into a from public.external_connection_audit_log x where x.trace_id = trace limit 1;
        select count(*) into n from public.external_connection_audit_log x where x.trace_id = trace;
        if n = 1 and (
             (i = 1 and a.reason_code = 'connection_not_found' and a.connection_id is null and a.principal_user_id = principal
                    and a.oauth_client_id = 'qa-sb827-unknown-client')
          or (i = 2 and a.reason_code = 'connection_principal_mismatch' and a.connection_id is null and a.principal_user_id = other
                    and a.oauth_client_id = cid)
          or (i = 3 and a.reason_code = 'connection_revoked' and a.connection_id = fx and a.principal_user_id = principal)
          or (i = 4 and a.reason_code = 'connection_expired' and a.connection_id = fx2 and a.principal_user_id = principal))
        then k := k + 1; else msg := msg || format('[case %s: rows %s reason %s] ', i, n, a.reason_code); end if;
      end loop;
      r := r || jsonb_build_object('TC-SB827-F4', case when k = 4 then 'pass' else format('FAIL: %s of 4 %s', k, msg) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F10 (v1.1, QA finding): verified session on its OWN active, unexpired connection sending
  -- identity reasons -> the DB does not trust the hint: connection_id NULL, reason identity_check_error,
  -- outcome error; nothing is attached to the live connection
  begin
    begin
      reset role;
      if exists (select 1 from public.external_connections c where c.id = conn and c.expires_at is not null and c.expires_at <= now()) then
        raise exception 'the active connection is expired; F10 needs an unexpired one';
      end if;
      select count(*) into j from public.external_connection_audit_log x
       where x.principal_user_id = principal and x.operation = 'auth' and x.created_at > now() - interval '60 seconds';
      if j + 4 > 10 or b_global + 4 > 30 then raise exception 'busy: % principal auth / % connection-less rows in the last minute; rerun', j, b_global; end if;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated', 'client_id', cid)::text, true);
      set local role authenticated;
      perform public.external_connection_record_auth_refusal('connection_revoked', trace);
      perform public.external_connection_record_auth_refusal('connection_disabled', trace);
      perform public.external_connection_record_auth_refusal('connection_expired', trace);
      perform public.external_connection_record_auth_refusal('connection_not_found', trace);
      reset role;
      select count(*) into n from public.external_connection_audit_log x
       where x.trace_id = trace and x.connection_id is null and x.reason_code = 'identity_check_error'
         and x.outcome = 'error' and x.operation = 'auth' and x.principal_user_id = principal and x.oauth_client_id = cid;
      select count(*) into m from public.external_connection_audit_log x where x.trace_id = trace;
      select count(*) into k from public.external_connection_audit_log x where x.trace_id = trace and x.connection_id is not null;
      r := r || jsonb_build_object('TC-SB827-F10', case when n = 4 and m = 4 and k = 0 then 'pass'
             else format('FAIL: identity_check_error unattached rows %s of 4, rows %s, attached %s', n, m, k) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F10', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F5a: anon bucket throttle — 15 calls -> 10 rows + 1 marker; 15 more -> nothing new
  begin
    begin
      reset role;
      if b_anon > 0 or b_global > 0 then raise exception 'busy: % anon / % connection-less rows in the last minute; rerun', b_anon, b_global; end if;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
      set local role anon;
      for i in 1..15 loop perform public.external_connection_record_auth_refusal('token_missing', trace); end loop;
      reset role;
      select count(*) filter (where reason_code = 'token_missing'), count(*) filter (where reason_code = 'auth_refusals_throttled')
        into n, m from public.external_connection_audit_log x where x.trace_id = trace;
      set local role anon;
      for i in 1..15 loop perform public.external_connection_record_auth_refusal('token_expired', trace); end loop;
      reset role;
      select count(*) into k from public.external_connection_audit_log x where x.trace_id = trace;
      r := r || jsonb_build_object('TC-SB827-F5a', case when n = 10 and m = 1 and k = 11 then 'pass'
             else format('FAIL: first 15 -> %s rows + %s markers; after 30 total %s', n, m, k) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F5a', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F5b: global cap — anon plus every looked-up user, 15 connection-less refusals each:
  -- at most 30 non-marker rows, at most one marker per bucket, at most 10 rows per bucket
  begin
    begin
      reset role;
      if b_anon > 0 or b_global > 0 then raise exception 'busy: % anon / % connection-less rows in the last minute; rerun', b_anon, b_global; end if;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
      set local role anon;
      for i in 1..15 loop perform public.external_connection_record_auth_refusal('token_invalid', trace); end loop;
      reset role;
      foreach u in array users loop
        perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
        set local role authenticated;
        for i in 1..15 loop perform public.external_connection_record_auth_refusal('token_expired', trace); end loop;
        reset role;
      end loop;
      select count(*) filter (where reason_code <> 'auth_refusals_throttled'), count(*) filter (where reason_code = 'auth_refusals_throttled')
        into n, m from public.external_connection_audit_log x where x.trace_id = trace and x.connection_id is null;
      select coalesce(max(c), 0) into k from (select count(*) c from public.external_connection_audit_log x
        where x.trace_id = trace and x.reason_code <> 'auth_refusals_throttled' group by x.principal_user_id) t;
      select coalesce(max(c), 0) into j from (select count(*) c from public.external_connection_audit_log x
        where x.trace_id = trace and x.reason_code = 'auth_refusals_throttled' group by x.principal_user_id) t;
      r := r || jsonb_build_object('TC-SB827-F5b', case
             when n <= 30 and n >= 20 and m between 1 and 1 + coalesce(array_length(users, 1), 0) and k <= 10 and j <= 1 then 'pass'
             else format('FAIL: non-marker %s, markers %s, max per bucket %s, max markers per bucket %s', n, m, k, j) end);
      r := r || jsonb_build_object('TC-SB827-F5b.evidence', format('%s buckets x 15 calls -> %s rows + %s markers', 1 + coalesce(array_length(users, 1), 0), n, m));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F5b', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F6: a sentinel passed in unverified claims or as a reason never lands in a row;
  -- oauth_client_id is only NULL or the verified claim
  begin
    begin
      reset role;
      if b_anon + 1 > 10 or b_global + 2 > 30 then raise exception 'busy: rerun'; end if;
      trace := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'anon', 'client_id', 'SENTINEL-CLIENT-827',
        'token', 'SENTINEL-TOKEN-827')::text, true);
      set local role anon;
      perform public.external_connection_record_auth_refusal('token_bad_signature', trace);
      st := 'no error';
      begin perform public.external_connection_record_auth_refusal('SENTINEL-TOKEN-827', trace); exception when others then st := sqlstate; end;
      reset role;
      perform set_config('request.jwt.claims', json_build_object('sub', principal, 'role', 'authenticated', 'session_id', 'SENTINEL-TOKEN-827')::text, true);
      set local role authenticated;
      perform public.external_connection_record_auth_refusal('token_expired', trace);
      reset role;
      select count(*) into n from public.external_connection_audit_log x where x.trace_id = trace;
      select count(*) into m from public.external_connection_audit_log x where x.trace_id = trace and row_to_json(x)::text like '%SENTINEL%';
      select count(*) into k from public.external_connection_audit_log x where x.trace_id = trace and x.oauth_client_id is not null;
      r := r || jsonb_build_object('TC-SB827-F6', case when n = 2 and m = 0 and k = 0 and st = '22023' then 'pass'
             else format('FAIL: rows %s, rows with sentinel %s, rows with a client id %s, bad reason sqlstate %s', n, m, k, st) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F7: auth rows never change precheck verdicts (1,000 on the live connection)
  begin
    begin
      reset role;
      select * into pr from public.external_connection_precheck(conn, 'list_work_items');
      select * into pw from public.external_connection_precheck(conn, 'create_work_item');
      insert into public.external_connection_audit_log (connection_id, principal_user_id, oauth_client_id, operation, outcome, reason_code)
        select conn, principal, cid, 'auth', 'denied', 'connection_expired' from generate_series(1, 1000);
      select * into pr2 from public.external_connection_precheck(conn, 'list_work_items');
      select * into pw2 from public.external_connection_precheck(conn, 'create_work_item');
      r := r || jsonb_build_object('TC-SB827-F7', case when pr.allowed and pw.allowed and pr2.allowed and pw2.allowed then 'pass'
             else format('FAIL: before read %s write %s; after read %s write %s', pr.allowed, pw.allowed, pr2.allowed, pw2.allowed) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F8: connection-less rows only for operation 'auth' (CHECK ecal_connection_or_auth_refusal)
  begin
    begin
      reset role;
      st := 'no error';
      begin
        insert into public.external_connection_audit_log (connection_id, operation, outcome) values (null, 'read', 'allowed');
      exception when others then st := sqlstate;
      end;
      r := r || jsonb_build_object('TC-SB827-F8', case when st = '23514' then 'pass' else format('FAIL: sqlstate %s', st) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB827-F8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- TC-SB827-F9: posture of the recorder (the deliberate SB-443 exception: anon may execute)
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.external_connection_record_auth_refusal(text, uuid)'::regprocedure
       and p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 'v'
       and p.prorettype = 'void'::regtype
       and has_function_privilege('anon', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and has_function_privilege('service_role', p.oid, 'execute')
       and not has_function_privilege('public', p.oid, 'execute');
    select count(*) into m from pg_constraint
     where conrelid = 'public.external_connection_audit_log'::regclass and conname = 'ecal_connection_or_auth_refusal';
    r := r || jsonb_build_object('TC-SB827-F9', case when n = 1 and m = 1 then 'pass' else format('FAIL: function posture %s, constraint %s', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB827-F9', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  reset role;
  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'EXT-CONN-LIMITS PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'EXT-CONN-LIMITS FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
