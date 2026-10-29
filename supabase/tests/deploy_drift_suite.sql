-- Deploy-drift suite: TC-SB617-01, TC-SB617-02, TC-SB617-03 (cron part), TC-SB617-04 (SB-617).
--
-- Run as postgres. One transaction that always ends by raising, so the fabricated responses,
-- ledger row, requests and activity_log rows it writes do not survive. Pass = the raised
-- message starts with "DEPLOY_DRIFT PASS". The message carries only counts and file names.
--
-- TC-SB617-01 fabricates pg_net responses for a synthetic run and checks every
-- classification: Pages live = main is clean; live different, live 404, or served-but-gone
-- is pages_not_live; release different is release_lag; a ledger file different from main,
-- or missing on main, is edge_not_on_main; a missing response, a timeout or a 5xx is
-- unverifiable; a file missing on main, Pages and the release branch is not_found. It also
-- checks that "since" carries over from the previous day (also through an unverifiable day),
-- that a second evaluation the same day replaces that day's row instead of adding one, that a
-- release branch that is 404 everywhere is one release_ref_missing flag, that a run older
-- than 5 hours is refused, and that path traversal in release_ref or a slug is refused.
-- TC-SB617-02 checks the latest real run (state as of the run; see the evidence).
-- TC-SB617-03 (cron part) and TC-SB617-04: schedule and posture.

do $suite$
declare
  r jsonb := '{}'::jsonb; v jsonb; run uuid := '00000000-0000-4000-8000-000000000617';
  run2 uuid := '00000000-0000-4000-8000-000000006172'; run3 uuid := '00000000-0000-4000-8000-000000006173'; st text;
  base bigint := 9000000000617000; n int; m int; fails int; viol jsonb; flags jsonb; real jsonb;
  sha_e text := encode(sha256(convert_to('E', 'UTF8')), 'hex');
  sha_x text := encode(sha256(convert_to('X', 'UTF8')), 'hex');
  sha_y text := encode(sha256(convert_to('Y', 'UTF8')), 'hex');
  pages constant text := 'https://jasonkpaulsen.github.io/supabrain-kanban/';
  raw   constant text := 'https://raw.githubusercontent.com/Jasonkpaulsen/supabrain-kanban/refs/heads/';
begin
  -- TC-SB617-04 posture
  r := r || jsonb_build_object('TC-SB617-04.rls',
         case when (select bool_and(relrowsecurity) from pg_class
                     where oid in ('public.edge_function_deploys'::regclass, 'public.deploy_drift_requests'::regclass))
              then 'pass' else 'FAIL: RLS off' end);
  r := r || jsonb_build_object('TC-SB617-04.tables',
         case when not (has_table_privilege('anon', 'public.edge_function_deploys', 'select,insert,update')
                     or has_table_privilege('authenticated', 'public.edge_function_deploys', 'select,insert,update')
                     or has_table_privilege('anon', 'public.deploy_drift_requests', 'select,insert,update')
                     or has_table_privilege('authenticated', 'public.deploy_drift_requests', 'select,insert,update'))
              then 'pass' else 'FAIL: a client role has table access' end);
  r := r || jsonb_build_object('TC-SB617-04.functions',
         case when not exists (
                select 1 from unnest(array['public.deploy_drift_fetch(text)', 'public.deploy_drift_evaluate(uuid)',
                                           'public.record_edge_function_deploy(text,integer,text,jsonb,text,timestamptz,text,text)']) f,
                              unnest(array['anon', 'authenticated']) ro
                 where has_function_privilege(ro, f, 'execute'))
              then 'pass' else 'FAIL: a client role can execute' end);
  select count(*) into n from public.deploy_drift_requests
   where url !~ '^https://(jasonkpaulsen\.github\.io/supabrain-kanban/|raw\.githubusercontent\.com/Jasonkpaulsen/supabrain-kanban/refs/heads/)';
  r := r || jsonb_build_object('TC-SB617-04.public_urls_only', case when n = 0 then 'pass' else 'FAIL: ' || n || ' other URLs' end);

  -- TC-SB617-03 cron part
  select count(*) into n from cron.job
   where active and ((jobname = 'deploy-drift-fetch' and schedule = '20 7 * * *' and command ~ 'deploy_drift_fetch\(')
                  or (jobname = 'deploy-drift-daily' and schedule = '25 7 * * *' and command ~ 'deploy_drift_evaluate\('));
  r := r || jsonb_build_object('TC-SB617-03.cron', case when n = 2 then 'pass' else 'FAIL: ' || n || ' of 2 jobs' end);

  -- TC-SB617-02: latest real run (before the synthetic one exists)
  select a.meta into real from public.activity_log a where a.target_table = 'deploy_drift' order by a.created_at desc limit 1;
  r := r || jsonb_build_object('TC-SB617-02.recorded', case when real is not null then 'pass' else 'FAIL: no deploy_drift row' end);
  if real is not null then
    select count(*) into n from jsonb_array_elements(real -> 'violations') x where x ->> 'type' = 'pages_not_live';
    select count(*) into m from jsonb_array_elements(real -> 'violations') x where x ->> 'type' = 'edge_not_on_main';
    r := r || jsonb_build_object('TC-SB617-02.evidence', format('checked %s, pages_not_live %s, edge_not_on_main %s (%s functions), release_lag %s, unverifiable %s',
           real ->> 'checked', n, m,
           (select count(distinct x ->> 'function') from jsonb_array_elements(real -> 'violations') x where x ->> 'type' = 'edge_not_on_main'),
           coalesce((select jsonb_array_length(f -> 'files') from jsonb_array_elements(real -> 'flags') f where f ->> 'type' = 'release_lag'), 0),
           coalesce((select jsonb_array_length(f -> 'checks') from jsonb_array_elements(real -> 'flags') f where f ->> 'type' = 'unverifiable'), 0)));
    -- Every recorded function's source is checked, and a run asks for every served file three ways.
    r := r || jsonb_build_object('TC-SB617-02.coverage',
           case when (real ->> 'checked')::int = 27 + (select count(*) from (select distinct on (slug) files from public.edge_function_deploys order by slug, version desc) l, jsonb_object_keys(l.files))
                then 'pass' else 'FAIL: checked ' || (real ->> 'checked') end);
  end if;

  -- TC-SB617-01: synthetic run
  insert into public.edge_function_deploys (slug, version, files, git_ref, deployed_at, recorded_by)
  values ('zz-sb617', 1, jsonb_build_object('index.ts', sha_e, 'x.ts', sha_x, 'y.ts', sha_y), 'fixture', now(), 'qa-sb617');
  insert into net._http_response (id, status_code, content, timed_out, created)
  select base + v.i, v.st, v.body, v.tmo, now() from (values
    (1, 200, 'A', false), (2, 200, 'A', false),          -- a.html  main, live: clean
    (3, 200, 'B', false), (4, 200, 'B2', false),         -- b.html  live differs
    (5, 200, 'C', false), (6, 404, 'nf', false),         -- c.html  live missing
    (7, 404, 'nf', false), (8, 200, 'D', false),         -- d.html  served but gone from main
    (9, 200, 'E1', false),                               -- e.html  live never answered (no row 10)
    (11, 200, 'F', false), (12, null, null, true),       -- f.html  live timed out
    (13, 500, 'oops', false), (14, 200, 'G', false),     -- g.html  main 5xx
    (15, 200, 'A', false), (16, 200, 'B3', false),       -- release a.html same, b.html differs
    (17, 200, 'E', false), (18, 200, 'X2', false), (19, 404, 'nf', false), -- edge index.ts ok, x.ts differs, y.ts gone
    (20, 404, 'nf', false), (21, 404, 'nf', false)       -- h.html  missing everywhere (no release row)
  ) v(i, st, body, tmo);
  insert into public.deploy_drift_requests (run_id, kind, slug, path, url, request_id, requested_at)
  select run, v.kind, v.slug, v.path,
         case when v.kind = 'pages_live' then pages || v.path else raw || 'main/' || v.path end, base + v.i, now()
    from (values
      ('pages_main', null, 'a.html', 1), ('pages_live', null, 'a.html', 2),
      ('pages_main', null, 'b.html', 3), ('pages_live', null, 'b.html', 4),
      ('pages_main', null, 'c.html', 5), ('pages_live', null, 'c.html', 6),
      ('pages_main', null, 'd.html', 7), ('pages_live', null, 'd.html', 8),
      ('pages_main', null, 'e.html', 9), ('pages_live', null, 'e.html', 10),
      ('pages_main', null, 'f.html', 11), ('pages_live', null, 'f.html', 12),
      ('pages_main', null, 'g.html', 13), ('pages_live', null, 'g.html', 14),
      ('pages_release', null, 'a.html', 15), ('pages_release', null, 'b.html', 16),
      ('edge_main', 'zz-sb617', 'index.ts', 17), ('edge_main', 'zz-sb617', 'x.ts', 18), ('edge_main', 'zz-sb617', 'y.ts', 19),
      ('pages_main', null, 'h.html', 20), ('pages_live', null, 'h.html', 21)
    ) v(kind, slug, path, i);
  -- yesterday's row says b.html has been out of date since 2026-10-01 and e.html unverifiable since 10-05
  insert into public.activity_log (project_id, user_id, agent_name, action, target_table, summary, meta, created_at)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'System', 'commented', 'deploy_drift',
          'fixture', jsonb_build_object('artifact', 'deploy_drift', 'since',
                     jsonb_build_object('pages:b.html', '2026-10-01 07:20:00+00', 'pages:e.html', '2026-10-05T07:20:00Z')),
          now() - interval '1 day');

  v := public.deploy_drift_evaluate(run);
  viol := v -> 'violations'; flags := v -> 'flags';
  r := r || jsonb_build_object('TC-SB617-01.pages_not_live',
         case when (select string_agg(x ->> 'file', ',' order by x ->> 'file') from jsonb_array_elements(viol) x where x ->> 'type' = 'pages_not_live') = 'b.html,c.html,d.html'
              then 'pass' else 'FAIL: ' || coalesce((select string_agg(x ->> 'file', ',' order by x ->> 'file') from jsonb_array_elements(viol) x where x ->> 'type' = 'pages_not_live'), 'none') end);
  r := r || jsonb_build_object('TC-SB617-01.edge_not_on_main',
         case when (select string_agg((x ->> 'file') || ':' || (x ->> 'on_main'), ',' order by x ->> 'file') from jsonb_array_elements(viol) x where x ->> 'type' = 'edge_not_on_main') = 'x.ts:true,y.ts:false'
              then 'pass' else 'FAIL: ' || coalesce((select string_agg(x ->> 'file', ',') from jsonb_array_elements(viol) x where x ->> 'type' = 'edge_not_on_main'), 'none') end);
  r := r || jsonb_build_object('TC-SB617-01.release_lag',
         case when (select string_agg(f2 ->> 'file', ',') from jsonb_array_elements(flags) f, jsonb_array_elements(f -> 'files') f2 where f ->> 'type' = 'release_lag') = 'b.html'
              then 'pass' else 'FAIL: release_lag wrong' end);
  r := r || jsonb_build_object('TC-SB617-01.unverifiable',
         case when (select string_agg(c ->> 'check', ',' order by c ->> 'check') from jsonb_array_elements(flags) f, jsonb_array_elements(f -> 'checks') c where f ->> 'type' = 'unverifiable') = 'pages:e.html,pages:f.html,pages:g.html'
              then 'pass' else 'FAIL: ' || coalesce((select string_agg(c ->> 'check', ',') from jsonb_array_elements(flags) f, jsonb_array_elements(f -> 'checks') c where f ->> 'type' = 'unverifiable'), 'none') end);
  r := r || jsonb_build_object('TC-SB617-01.since_carried',
         case when (select x ->> 'since' from jsonb_array_elements(viol) x where x ->> 'file' = 'b.html') = '2026-10-01T07:20:00Z'
               and (select x ->> 'since' from jsonb_array_elements(viol) x where x ->> 'file' = 'c.html') <> '2026-10-01T07:20:00Z'
               and (select c ->> 'since' from jsonb_array_elements(flags) f, jsonb_array_elements(f -> 'checks') c
                     where f ->> 'type' = 'unverifiable' and c ->> 'check' = 'pages:e.html') = '2026-10-05T07:20:00Z'
              then 'pass' else 'FAIL: since not carried' end);
  r := r || jsonb_build_object('TC-SB617-01.not_found',
         case when (select string_agg(f2 ->> 'file', ',') from jsonb_array_elements(flags) f, jsonb_array_elements(f -> 'files') f2 where f ->> 'type' = 'not_found') = 'h.html'
              then 'pass' else 'FAIL: not_found wrong' end);
  r := r || jsonb_build_object('TC-SB617-01.summary',
         case when v ->> 'summary' = 'Deploy drift: 5 violation(s) (3 Pages file(s) not live, 2 edge-function file(s) not on main), 1 release-lag file(s), 3 unverifiable check(s). 1 served file(s) found nowhere.'
              then 'pass' else 'FAIL: ' || (v ->> 'summary') end);
  perform public.deploy_drift_evaluate(run);
  select count(*) into n from public.activity_log a where a.target_table = 'deploy_drift' and a.created_at::date = current_date;
  r := r || jsonb_build_object('TC-SB617-01.one_row_per_day', case when n = 1 then 'pass' else 'FAIL: ' || n || ' rows today' end);

  -- a clean synthetic run says so
  update net._http_response set content = 'A', status_code = 200, timed_out = false where id between base + 1 and base + 16 or id in (base + 20, base + 21);
  update net._http_response set content = 'X', status_code = 200 where id = base + 18;
  update net._http_response set content = 'Y', status_code = 200 where id = base + 19;
  insert into net._http_response (id, status_code, content, timed_out, created) values (base + 10, 200, 'A', false, now());
  v := public.deploy_drift_evaluate(run);
  r := r || jsonb_build_object('TC-SB617-01.clean',
         case when v ->> 'summary' like 'Deploy drift: all clear%' and jsonb_array_length(v -> 'violations') = 0
              then 'pass' else 'FAIL: ' || (v ->> 'summary') end);

  -- a release branch that is 404 everywhere is gone, not lagging
  insert into net._http_response (id, status_code, content, timed_out, created)
  select base + v.i, v.st, v.body, false, now() from (values (31, 200, 'A'), (32, 200, 'A'), (33, 404, 'nf'),
                                                            (34, 200, 'B'), (35, 200, 'B'), (36, 404, 'nf')) v(i, st, body);
  insert into public.deploy_drift_requests (run_id, kind, path, url, request_id, requested_at)
  select run2, v.kind, v.path, case when v.kind = 'pages_live' then pages || v.path
                                    when v.kind = 'pages_main' then raw || 'main/' || v.path else raw || 'gone-branch/' || v.path end,
         base + v.i, now() + interval '1 second'
    from (values ('pages_main', 'a.html', 31), ('pages_live', 'a.html', 32), ('pages_release', 'a.html', 33),
                 ('pages_main', 'b.html', 34), ('pages_live', 'b.html', 35), ('pages_release', 'b.html', 36)) v(kind, path, i);
  v := public.deploy_drift_evaluate(run2);
  r := r || jsonb_build_object('TC-SB617-01.release_ref_missing',
         case when (select count(*) from jsonb_array_elements(v -> 'flags') f where f ->> 'type' = 'release_ref_missing' and f ->> 'ref' = 'gone-branch') = 1
               and not exists (select 1 from jsonb_array_elements(v -> 'flags') f where f ->> 'type' = 'release_lag')
              then 'pass' else 'FAIL: ' || (v -> 'flags')::text end);

  -- a run fetched more than 5 hours ago is refused, not evaluated into an all-unverifiable day
  insert into public.deploy_drift_requests (run_id, kind, path, url, request_id, requested_at)
  values (run3, 'pages_main', 'a.html', raw || 'main/a.html', base + 31, now() - interval '6 hours');
  begin
    perform public.deploy_drift_evaluate(run3); st := 'evaluated';
  exception when others then st := sqlstate;
  end;
  r := r || jsonb_build_object('TC-SB617-01.stale_run_refused', case when st = '55000' then 'pass' else 'FAIL: ' || st end);

  -- path traversal is refused before any request is made
  begin
    perform public.deploy_drift_fetch('../../../../evil/repo/refs/heads/main'); st := 'fetched';
  exception when others then st := sqlstate;
  end;
  r := r || jsonb_build_object('TC-SB617-04.release_ref_validated', case when st = '22023' then 'pass' else 'FAIL: ' || st end);
  begin
    perform public.record_edge_function_deploy('../evil', 1, null, jsonb_build_object('index.ts', sha_e), 'x', now(), 'qa');
    st := 'recorded';
  exception when others then st := sqlstate;
  end;
  r := r || jsonb_build_object('TC-SB617-04.slug_validated', case when st = '22023' then 'pass' else 'FAIL: ' || st end);

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'DEPLOY_DRIFT PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  else
    raise exception 'DEPLOY_DRIFT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  end if;
end $suite$;
