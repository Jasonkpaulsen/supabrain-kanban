-- Project automation toggle suite: TC-SB623-01, TC-SB623-02, TC-SB623-03 (SB-623).
-- TC-SB623-04 is tests/e2e/project-automation.spec.js.
--
-- Run as postgres. One transaction that always ends by raising, so the fixture project and
-- the role and JWT claims it sets do not survive. Pass = the raised message starts with
-- "PROJECT_AUTOMATION_TOGGLE PASS". The message carries only states and counts.
--
-- TC-SB623-01: the owner turns automation on and off; the RPC writes
-- projects.automation_status (what agent-runner reads, SB-390), returns the documented keys,
-- and leaves meta alone. TC-SB623-02: a non-owner is refused and the row is unchanged; anon
-- cannot call it; it is SECURITY INVOKER, so RLS decides. TC-SB623-03: the runner's project
-- predicate picks the project up after "on" and drops it after "off".

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  other constant uuid := '00000000-0000-4000-8000-000000000623'; -- not a project member
  fn constant regprocedure := 'public.set_project_dev_automation(uuid,boolean)'::regprocedure;
  pid uuid;
  r jsonb := '{}'::jsonb;
  v jsonb; st text; mt jsonb; n int; fails int;
begin
  -- domain is explicit: it is required and has no default (SB-624).
  insert into public.projects (name, user_id, domain, automation_status, meta)
  values ('ZZ SB623 toggle fixture', ub, 'operations', 'paused', '{"keep": 1}'::jsonb)
  returning id into pid;

  -- runner predicate (agent-runner: archived = false and automation_status = 'active')
  select count(*) into n from public.projects where id = pid and not archived and automation_status = 'active';
  r := r || jsonb_build_object('TC-SB623-03.before', case when n = 0 then 'pass' else 'FAIL: paused fixture selected' end);

  -- TC-SB623-01 as the owner
  perform set_config('request.jwt.claims', jsonb_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v := public.set_project_dev_automation(pid, true);
  reset role;
  select automation_status, meta into st, mt from public.projects where id = pid;
  r := r || jsonb_build_object('TC-SB623-01.on',
         case when v = jsonb_build_object('ok', true, 'project', 'ZZ SB623 toggle fixture',
                                          'automation_status', 'active', 'dev_automation', 'on')
               and st = 'active' then 'pass'
              else 'FAIL: on returned ' || coalesce(v->>'automation_status', v->>'error', 'null') || ', row ' || st end);
  select count(*) into n from public.projects where id = pid and not archived and automation_status = 'active';
  r := r || jsonb_build_object('TC-SB623-03.after_on', case when n = 1 then 'pass' else 'FAIL: active fixture not selected' end);

  -- TC-SB623-02 as a non-owner, while the row is active
  perform set_config('request.jwt.claims', jsonb_build_object('sub', other, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v := public.set_project_dev_automation(pid, false);
  reset role;
  select automation_status into st from public.projects where id = pid;
  r := r || jsonb_build_object('TC-SB623-02.non_owner',
         case when v = jsonb_build_object('ok', false, 'error', 'project not found or not yours') and st = 'active' then 'pass'
              else 'FAIL: non-owner got ' || coalesce(v->>'ok', 'null') || ', row ' || st end);

  -- back to the owner: null is refused, off writes paused
  perform set_config('request.jwt.claims', jsonb_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v := public.set_project_dev_automation(pid, null);
  r := r || jsonb_build_object('TC-SB623-01.null',
         case when v->>'ok' = 'false' and v->>'error' = 'p_on is required' then 'pass' else 'FAIL: null accepted' end);
  v := public.set_project_dev_automation(pid, false);
  reset role;
  select automation_status, meta into st, mt from public.projects where id = pid;
  r := r || jsonb_build_object('TC-SB623-01.off',
         case when v->>'ok' = 'true' and v->>'automation_status' = 'paused' and v->>'dev_automation' = 'off'
               and st = 'paused' then 'pass'
              else 'FAIL: off returned ' || coalesce(v->>'automation_status', v->>'error', 'null') || ', row ' || st end);
  r := r || jsonb_build_object('TC-SB623-01.meta',
         case when mt = '{"keep": 1}'::jsonb then 'pass' else 'FAIL: meta changed (keys ' ||
              (select string_agg(k, ',') from jsonb_object_keys(mt) k) || ')' end);
  select count(*) into n from public.projects where id = pid and not archived and automation_status = 'active';
  r := r || jsonb_build_object('TC-SB623-03.after_off', case when n = 0 then 'pass' else 'FAIL: paused fixture selected' end);

  -- TC-SB623-02 posture
  r := r || jsonb_build_object('TC-SB623-02.invoker',
         case when not (select prosecdef from pg_proc where oid = fn) then 'pass' else 'FAIL: SECURITY DEFINER' end);
  r := r || jsonb_build_object('TC-SB623-02.grants',
         case when not has_function_privilege('anon', fn, 'execute')
               and has_function_privilege('authenticated', fn, 'execute') then 'pass'
              else 'FAIL: execute grants wrong' end);

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'PROJECT_AUTOMATION_TOGGLE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'PROJECT_AUTOMATION_TOGGLE FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
