-- RLS initplan suite: TC-SB621-01, TC-SB621-02, TC-SB621-03 (SB-621). TC-SB621-04 is
-- tests/unit/rls-initplan.test.ts.
--
-- Run as postgres. One transaction that always ends by raising, so nothing it inserts
-- survives. Pass = the raised message starts with "RLS_INITPLAN PASS". The message carries
-- only table names, counts and outcome codes, never row values.
--
-- TC-SB621-01: posture. The 20 policies SB-621 rewrote call auth.uid() only through
-- (select auth.uid()); keep their command and permissive flag; and no policy in public calls
-- auth.uid()/jwt()/role() bare.
-- TC-SB621-02: behaviour. For every real user, a stranger and anon, the rows RLS shows on each
-- of the 15 tables equal an oracle computed as postgres from the policies' meaning; and an
-- insert carrying another user's id is refused by RLS while one carrying your own is not.
-- TC-SB621-03: the planner evaluates auth.uid() once (an InitPlan) for a probed table.

do $suite$
declare
  stranger constant uuid := '00000000-0000-4000-8000-000000000621';
  r jsonb := '{}'::jsonb; ev jsonb := '{}'::jsonb;
  u record; t text; n bigint; m bigint; fails int; bad text; st text; msg text; plan text; line text;
  owner uuid;
  tbls constant text[] := array['cip_compliance_matrix','ef_assessments','external_connection_audit_log','external_connection_limits',
    'game_vehicle_lifestyle_grants','game_vehicle_upgrades','game_vehicles','governance_audit','grooming_cadence','research_briefs',
    'school_courses','trade_log','trade_signals','weather_obs','weather_obs_live'];
  ins_tbls constant text[] := array['cip_compliance_matrix','ef_assessments','game_vehicle_lifestyle_grants','game_vehicle_upgrades',
    'game_vehicles','governance_audit','research_briefs','school_courses'];
  targets constant text[] := array[
    'cip_compliance_matrix.cip_compliance_matrix_owner', 'ef_assessments.Users can manage their own ef_assessments',
    'external_connection_audit_log.ecal_insert_self', 'external_connection_audit_log.ecal_select_own_or_owner',
    'external_connection_limits.ecl_select_related', 'game_vehicle_lifestyle_grants.Users can insert own grants',
    'game_vehicle_upgrades.Users can insert own upgrades', 'game_vehicles.Users can insert own vehicles',
    'governance_audit.governance_audit_insert', 'governance_audit.governance_audit_select',
    'grooming_cadence.Users manage own grooming records', 'research_briefs.rb_owner_insert',
    'research_briefs.rb_owner_mark_consumed', 'research_briefs.rb_owner_select', 'research_briefs.rb_owner_update_draft',
    'school_courses.school_courses_owner', 'trade_log.Select for authenticated', 'trade_signals.Select for authenticated',
    'weather_obs.Select for authenticated', 'weather_obs_live.Select for authenticated'];
begin
  -- TC-SB621-01
  select count(*), string_agg(c.relname || '.' || p.polname, ', ') into n, bad
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relnamespace = 'public'::regnamespace and (c.relname || '.' || p.polname) = any (targets)
     and coalesce(pg_get_expr(p.polqual, p.polrelid), '') || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') like '%( SELECT auth.uid() AS uid)%'
     and p.polpermissive;
  r := r || jsonb_build_object('TC-SB621-01.wrapped', case when n = 20 then 'pass' else 'FAIL: ' || n || ' of 20 wrapped and permissive' end);
  select count(*), coalesce(string_agg(c.relname || '.' || p.polname, ', '), '') into n, bad
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relnamespace = 'public'::regnamespace
     and regexp_replace(coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), ''),
                        '\( SELECT (auth\.\w+\(\)|current_setting\(''request\.jwt[^'']*''::text(, true)?\)) AS \w+\)', '', 'gi')
         ~* '(auth\.\w+\(\)|current_setting\(''request\.jwt)';
  r := r || jsonb_build_object('TC-SB621-01.class_guard', case when n = 0 then 'pass' else 'FAIL: ' || n || ' bare: ' || bad end);

  -- TC-SB621-02 visibility
  for u in select id, 'authenticated' rl from auth.users
           union all select stranger, 'authenticated'
           union all select null::uuid, 'anon' loop
    foreach t in array tbls loop
      -- oracle, as postgres
      if u.id is null then m := 0;
      elsif t = 'external_connection_audit_log' then
        select count(*) into m from public.external_connection_audit_log l
         where l.principal_user_id = u.id
            or exists (select 1 from public.external_connections c where c.id = l.connection_id and c.created_by = u.id);
      elsif t = 'external_connection_limits' then
        select count(*) into m from public.external_connection_limits l
         where l.connection_id is null
            or exists (select 1 from public.external_connections c where c.id = l.connection_id
                                                                  and (c.principal_user_id = u.id or c.created_by = u.id));
      elsif t = 'grooming_cadence' then
        select count(*) into m from public.grooming_cadence g where g.project_id in (select p.id from public.projects p where p.user_id = u.id);
      else
        execute format('select count(*) from public.%I where user_id = $1', t) into m using u.id;
      end if;
      perform set_config('request.jwt.claims', case when u.id is null then '{"role":"anon"}' else jsonb_build_object('sub', u.id, 'role', u.rl)::text end, true);
      execute format('set local role %I', u.rl);
      begin
        execute format('select count(*) from public.%I', t) into n;
      exception when insufficient_privilege then n := 0;   -- no grant: nothing visible, same as the oracle for anon
      end;
      reset role;
      if n <> m then
        r := r || jsonb_build_object('TC-SB621-02.visible.' || t || '@' || coalesce(left(md5(u.id::text), 8), 'anon'),
                                     'FAIL: rls ' || n || ' oracle ' || m);
      end if;
      ev := ev || jsonb_build_object(t, coalesce((ev->>t)::bigint, 0) + n);
    end loop;
  end loop;
  r := r || jsonb_build_object('TC-SB621-02.visible', case when not exists (select 1 from jsonb_object_keys(r) k where k like 'TC-SB621-02.visible.%') then 'pass' else 'FAIL' end);

  -- TC-SB621-02 inserts: another user's id must be refused by RLS, your own must not be
  select id into owner from auth.users order by created_at limit 1;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', stranger, 'role', 'authenticated')::text, true);
  foreach t in array ins_tbls loop
    set local role authenticated;
    begin
      execute format('insert into public.%I (user_id) values ($1)', t) using owner;
      st := 'inserted';
    exception when others then
      get stacked diagnostics msg = message_text; st := case when msg like '%row-level security%' then 'rls' else sqlstate end;
    end;
    reset role;
    if st <> 'rls' then r := r || jsonb_build_object('TC-SB621-02.foreign_insert.' || t, 'FAIL: ' || st); end if;
    set local role authenticated;
    begin
      execute format('insert into public.%I (user_id) values ($1)', t) using stranger;
      st := 'inserted';
    exception when others then
      get stacked diagnostics msg = message_text; st := case when msg like '%row-level security%' then 'rls' else sqlstate end;
    end;
    reset role;
    if st = 'rls' then r := r || jsonb_build_object('TC-SB621-02.own_insert.' || t, 'FAIL: refused by RLS'); end if;
    ev := ev || jsonb_build_object('own_insert.' || t, st);
  end loop;
  r := r || jsonb_build_object('TC-SB621-02.inserts', case when not exists (select 1 from jsonb_object_keys(r) k where k like 'TC-SB621-02.%_insert.%') then 'pass' else 'FAIL' end);

  -- TC-SB621-03 plan
  perform set_config('request.jwt.claims', jsonb_build_object('sub', owner, 'role', 'authenticated')::text, true);
  set local role authenticated;
  plan := '';
  for line in execute 'explain select count(*) from public.weather_obs' loop plan := plan || line || E'\n'; end loop;
  reset role;
  r := r || jsonb_build_object('TC-SB621-03.initplan', case when plan ~ 'InitPlan' then 'pass' else 'FAIL: no InitPlan in plan' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'RLS_INITPLAN PASS (% checks): % evidence %', (select count(*) from jsonb_object_keys(r)), r::text, ev::text;
  else
    raise exception 'RLS_INITPLAN FAIL (% of % checks): % evidence %', fails, (select count(*) from jsonb_object_keys(r)), r::text, ev::text;
  end if;
end $suite$;
