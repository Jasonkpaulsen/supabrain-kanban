-- pg_net exposure suite: TC-SB514-01 .. TC-SB514-04 (SB-514).
--
-- Run as postgres. One transaction that always ends by raising, so the probe memory and the
-- pg_net request it queues do not survive. Pass = the raised message starts with
-- "PG_NET_EXPOSURE PASS". The message carries only function names and counts.
--
-- The PUBLIC grants on net are the platform default and cannot be revoked from here, so the
-- rule is on the path instead: no function anon or authenticated can execute calls net.http_*
-- (TC-SB514-01). The three trigger functions client writes fire run as their owner, and a
-- client insert still fires one (TC-SB514-02). TC-SB514-03 reports the residual grants.
-- TC-SB514-04 (verifier, 2026-10-23): a text match for net.http_ cannot see a function that
-- runs caller-supplied SQL, so no client-executable public function may build dynamic SQL
-- with %s (detector_field_adoption did, and anon could run any SQL through it).

do $suite$
declare
  r jsonb := '{}'::jsonb; n int; fails int; bad text; q0 bigint; q1 bigint; st text;
begin
  -- TC-SB514-01
  select count(*), string_agg(n2.nspname || '.' || p.oid::regprocedure::text, ', ') into n, bad
    from pg_proc p join pg_namespace n2 on n2.oid = p.pronamespace
   where n2.nspname not in ('net', 'pg_catalog', 'information_schema')
     and p.prorettype <> 'event_trigger'::regtype
     and p.prosrc ~* '\mnet\.http_'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  r := r || jsonb_build_object('TC-SB514-01.no_client_net_callers', case when n = 0 then 'pass' else 'FAIL: ' || bad end);

  -- TC-SB514-02 posture
  select count(*) into n from pg_proc p
   where p.oid in ('public.trigger_memory_embedding()'::regprocedure, 'public.trigger_image_analysis()'::regprocedure,
                   'public.fn_trigger_skill_embedding()'::regprocedure)
     and p.prosecdef and p.proconfig = array['search_path=""'];
  r := r || jsonb_build_object('TC-SB514-02.triggers_definer', case when n = 3 then 'pass' else 'FAIL: ' || n || ' of 3' end);
  -- TC-SB514-02 behaviour: an authenticated insert fires the embedding trigger
  select count(*) into q0 from net.http_request_queue;
  perform set_config('request.jwt.claims', '{"sub":"5ecbd44a-a3e2-4363-9133-dff3851ba0f5","role":"authenticated"}', true);
  set local role authenticated;
  begin
    insert into public.memories (project_id, type, content, user_id, scope)
    values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', 'insight', 'qa-sb514 probe', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'project');
    st := 'inserted';
  exception when others then st := sqlstate;
  end;
  reset role;
  select count(*) into q1 from net.http_request_queue;
  r := r || jsonb_build_object('TC-SB514-02.client_write_fires',
         case when st = 'inserted' and q1 - q0 = 1 then 'pass' else 'FAIL: ' || st || ', queued ' || (q1 - q0) end);

  -- TC-SB514-04 no client-executable dynamic SQL built with %s
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosrc ~* '\mexecute\M' and p.prosrc ~ '%s'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  r := r || jsonb_build_object('TC-SB514-04.no_client_dynamic_sql', case when bad is null then 'pass' else 'FAIL: ' || bad end);
  r := r || jsonb_build_object('TC-SB514-04.detector_adoption_service_only',
         case when not has_function_privilege('anon', 'public.detector_field_adoption(text,text,numeric)', 'execute')
                   and not has_function_privilege('authenticated', 'public.detector_field_adoption(text,text,numeric)', 'execute')
                   and has_function_privilege('service_role', 'public.detector_field_adoption(text,text,numeric)', 'execute')
              then 'pass' else 'FAIL' end);

  -- TC-SB514-03 residual platform default, reported
  r := r || jsonb_build_object('TC-SB514-03.evidence', format('net: %s of %s functions executable by anon (PUBLIC grant by %s); pgsodium: %s executable by anon; neither schema exposed (pgrst.db_schemas %s)',
         (select count(*) from pg_proc p where p.pronamespace = 'net'::regnamespace and has_function_privilege('anon', p.oid, 'execute')),
         (select count(*) from pg_proc p where p.pronamespace = 'net'::regnamespace),
         (select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'net'),
         (select count(*) from pg_proc p where p.pronamespace = 'pgsodium'::regnamespace and has_function_privilege('anon', p.oid, 'execute')),
         coalesce(current_setting('pgrst.db_schemas', true), 'default')));

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'PG_NET_EXPOSURE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  else
    raise exception 'PG_NET_EXPOSURE FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  end if;
end $suite$;
