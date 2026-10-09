-- CRM steward schedule suite: TC-SB576-1..13 (SB-576; ADR-CRM-006 §4.2 "Scheduling", as amended).
--
-- Verifies crm_steward_scheduled(p_task), the pg_cron job crm-steward-daily, and the onboarding of
-- the "CRM Data Steward" agent. Run as postgres. The whole suite is one transaction that always
-- ends by raising, so nothing it changes survives. On top of that, every case that changes data
-- (automation_enabled, status, a revoked grant, a fixture agent) runs in its own sub-block that
-- raises a private sentinel at its end, so its changes are rolled back before the next case starts
-- and automation_enabled is never left true, even inside the transaction.
--
-- Cases 4-7, 12 and 13 run the job's real command text, read from cron.job and run with EXECUTE,
-- exactly as pg_cron would run it. Case 6 runs the real steward (crm_steward_run(false, 200)) on
-- the owner's data, but only inside its rolled-back sub-block.
-- Pass = the raised message starts with "CRM-STEWARD-SCHEDULE PASS". The message carries only
-- counts, ids, statuses and sqlstates, never CRM names, emails or phones.
--
-- Each case is wrapped in its own sub-block, so an error in one case is reported as that case's
-- FAIL and does not stop the others.

do $suite$
declare
  ub     constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';           -- owner
  aid    constant uuid := '35c61865-2677-42fd-aad3-d2aa8fa81e85';           -- CRM Data Steward
  sb     constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';           -- SB project
  skill_md5 constant text := '883804f1500b90f3f77e0f91deedadbe';            -- SKILL.md (device + repo-independent copy)
  fn_md5    constant text := 'bc7f874c33c447d1fcc40745dc86d9f0';            -- body of 20261009031412_sb575_..._qa_sampling.sql (adds 'weekly'; daily path unchanged)
  rb     constant text := '__sb576_rollback__';
  r jsonb := '{}'::jsonb;
  cmd text; n int; m int; k int; fails int; st text; msg text; res jsonb;
  runs0 int; runs1 int; rc0 int; rc1 int; ec0 int; ec1 int; dec0 int; dec1 int;
  lra0 timestamptz; lra1 timestamptz; upd0 timestamptz; upd1 timestamptz; le1 text;
  cu text; uid uuid; other uuid; fx uuid;
  ar public.agent_runs%rowtype;
  fn text;
begin
  select c.command into cmd from cron.job c where c.jobname = 'crm-steward-daily';

  -- ------------------------------------------------ TC-SB576-1: security posture and the anon grant
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.crm_steward_scheduled(text)'::regprocedure
       and not p.prosecdef and p.proconfig @> array['search_path=""'] and p.provolatile = 'v'
       and not has_function_privilege('anon', p.oid, 'execute')
       and not has_function_privilege('public', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and has_function_privilege('service_role', p.oid, 'execute');
    -- anon is refused at the privilege check (not at the auth check), even with the owner's claims
    st := null; msg := null;
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'anon')::text, true);
      set local role anon;
      perform public.crm_steward_scheduled('daily');
      st := 'no error';
    exception when others then
      st := sqlstate; msg := sqlerrm;
    end;
    reset role;
    r := r || jsonb_build_object('TC-SB576-1', case
           when n = 1 and st = '42501' and msg like 'permission denied for function%'
           then 'pass' else format('FAIL: posture ok %s of 1, anon call %s (%s)', n, st, left(coalesce(msg, ''), 80)) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-2: no auth.uid() -> 42501
  begin
    k := 0;
    select count(*) into n from public.agent_runs where agent_id = aid;
    -- (a) as authenticated with no claims at all; (b) as postgres with no claims
    foreach fn in array array['authenticated', 'postgres'] loop
      st := null; msg := null;
      begin
        perform set_config('request.jwt.claims', '', true);
        perform set_config('request.jwt.claim.sub', '', true);
        if fn = 'authenticated' then set local role authenticated; end if;
        perform public.crm_steward_scheduled('daily');
        st := 'no error';
      exception when others then
        st := sqlstate; msg := sqlerrm;
      end;
      reset role;
      if st = '42501' and msg like '%signed-in owner%' then k := k + 1; end if;
    end loop;
    r := r || jsonb_build_object('TC-SB576-2', case
           when k = 2 and n = (select count(*) from public.agent_runs where agent_id = aid)
           then 'pass' else format('FAIL: refused %s of 2 (last %s)', k, st) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-3: unknown task -> 22023 ('weekly' is a task since SB-575)
  begin
    k := 0;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    foreach fn in array array['monthly', 'DAILY', 'daily ', '', '__null__'] loop
      st := null;
      begin
        perform public.crm_steward_scheduled(case when fn = '__null__' then null else fn end);
        st := 'no error';
      exception when others then
        st := sqlstate;
      end;
      if st = '22023' then k := k + 1; end if;
    end loop;
    reset role;
    r := r || jsonb_build_object('TC-SB576-3', case
           when k = 5 then 'pass' else format('FAIL: refused %s of 5 bad tasks', k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-4: no-op while automation is off (exact cron command)
  begin
    begin
      reset role;
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      select run_count, error_count, last_run_at, updated_at into rc0, ec0, lra0, upd0 from public.agents where id = aid;
      select count(*) into dec0 from public.crm_steward_decisions;
      if (select automation_enabled from public.agents where id = aid) then
        raise exception 'precondition: automation_enabled is already true';
      end if;
      execute cmd;                                   -- the job's own text, as pg_cron runs it
      cu := current_user; uid := auth.uid();
      -- and the wrapper's own answer, as the owner
      res := public.crm_steward_scheduled('daily');
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      select run_count, error_count, last_run_at, updated_at into rc1, ec1, lra1, upd1 from public.agents where id = aid;
      select count(*) into dec1 from public.crm_steward_decisions;
      r := r || jsonb_build_object('TC-SB576-4', case
             when runs1 = runs0 and rc1 is not distinct from rc0 and ec1 is not distinct from ec0
              and lra1 is not distinct from lra0 and upd1 is not distinct from upd0 and dec1 = dec0
              and (res->>'skipped')::boolean and res->>'task' = 'daily'
              and cu = 'authenticated' and uid = ub
             then 'pass' else format('FAIL: runs %s->%s run_count %s->%s decisions %s->%s res %s role %s',
                                     runs0, runs1, rc0, rc1, dec0, dec1, res, cu) end);
      r := r || jsonb_build_object('TC-SB576-4.evidence', format('agent_runs %s->%s, run_count %s->%s, decisions %s->%s, wrapper %s',
                                     runs0, runs1, rc0, rc1, dec0, dec1, res));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB576-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB576-5: no-op when status <> 'active' with automation on
  begin
    k := 0; msg := '';
    foreach fn in array array['paused', 'disabled', 'archived'] loop
      begin
        reset role;
        update public.agents set automation_enabled = true, status = fn where id = aid;
        select count(*) into runs0 from public.agent_runs where agent_id = aid;
        select run_count into rc0 from public.agents where id = aid;
        select count(*) into dec0 from public.crm_steward_decisions;
        execute cmd;
        res := public.crm_steward_scheduled('daily');
        reset role;
        select count(*) into runs1 from public.agent_runs where agent_id = aid;
        select run_count into rc1 from public.agents where id = aid;
        select count(*) into dec1 from public.crm_steward_decisions;
        if runs1 = runs0 and rc1 is not distinct from rc0 and dec1 = dec0 and (res->>'skipped')::boolean then
          k := k + 1;
        else
          msg := msg || format('[%s: runs %s->%s rc %s->%s dec %s->%s] ', fn, runs0, runs1, rc0, rc1, dec0, dec1);
        end if;
        raise exception '%', rb;
      exception when others then
        if sqlerrm <> rb then msg := msg || format('[%s: error %s %s] ', fn, sqlstate, sqlerrm); end if;
      end;
    end loop;
    r := r || jsonb_build_object('TC-SB576-5', case when k = 3 then 'pass' else 'FAIL: ' || msg end);
  end;

  -- ------------------------------------------------ TC-SB576-6: enabled run via the exact cron command
  begin
    begin
      reset role;
      update public.agents set automation_enabled = true where id = aid and status = 'active';
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      select run_count, error_count into rc0, ec0 from public.agents where id = aid;
      execute cmd;
      cu := current_user; uid := auth.uid();         -- the session the job left: what the INVOKER function ran as
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      select run_count, error_count, last_run_at into rc1, ec1, lra1 from public.agents where id = aid;
      select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
      r := r || jsonb_build_object('TC-SB576-6', case
             when cu = 'authenticated' and uid = ub
              and runs1 = runs0 + 1
              and ar.status = 'completed' and ar.trigger_type = 'scheduled'
              and ar.user_id = ub and ar.project_id = sb
              and ar.run_metadata->>'task' = 'daily' and ar.run_metadata->>'source' = 'crm_steward_scheduled'
              and ar.run_metadata->'summary' is not null and jsonb_typeof(ar.run_metadata->'summary') = 'object'
              and not coalesce((ar.run_metadata#>>'{summary,dry_run}')::boolean, true)
              and not coalesce((ar.run_metadata#>>'{summary,disabled}')::boolean, false)
              and ar.duration_ms is not null and ar.finished_at >= ar.started_at
              and ar.error_message is null and ar.error_code is null
              and ar.result_summary like 'decisions %'
              and rc1 = coalesce(rc0, 0) + 1 and ec1 is not distinct from ec0 and lra1 is not null
             then 'pass' else format('FAIL: role %s uid_is_owner %s runs %s->%s status %s trigger %s project_is_sb %s task %s dur %s err %s rc %s->%s ec %s->%s',
                                     cu, uid = ub, runs0, runs1, ar.status, ar.trigger_type, ar.project_id = sb,
                                     ar.run_metadata->>'task', ar.duration_ms, ar.error_code, rc0, rc1, ec0, ec1) end);
      r := r || jsonb_build_object('TC-SB576-6.evidence', format('run %s: %s, duration_ms %s, %s', ar.id, ar.status, ar.duration_ms, ar.result_summary));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB576-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB576-7: failure path (steward raises) -> failed run, no abort
  begin
    begin
      reset role;
      revoke execute on function public.crm_steward_run(boolean, integer) from authenticated;
      update public.agents set automation_enabled = true where id = aid and status = 'active';
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      select run_count, error_count into rc0, ec0 from public.agents where id = aid;
      st := 'no error';
      begin
        execute cmd;
      exception when others then
        st := sqlstate || ' ' || sqlerrm;
      end;
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      select run_count, error_count, last_error into rc1, ec1, le1 from public.agents where id = aid;
      select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
      r := r || jsonb_build_object('TC-SB576-7', case
             when st = 'no error' and runs1 = runs0 + 1
              and ar.status = 'failed' and ar.trigger_type = 'scheduled' and ar.error_code = '42501'
              and ar.error_message like '42501: permission denied%' and ar.finished_at is not null
              and ar.run_metadata->>'task' = 'daily'
              and ec1 = coalesce(ec0, 0) + 1 and rc1 = coalesce(rc0, 0) + 1 and le1 = ar.error_message
             then 'pass' else format('FAIL: job %s runs %s->%s status %s code %s ec %s->%s rc %s->%s last_error_set %s',
                                     st, runs0, runs1, ar.status, ar.error_code, ec0, ec1, rc0, rc1, le1 is not null) end);
      r := r || jsonb_build_object('TC-SB576-7.evidence', format('run %s: %s, %s', ar.id, ar.status, ar.error_message));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB576-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB576-8: the cron job
  -- As amended after D1 (migration 20261009024437_sb576_steward_job_pin_owner_by_agent_id): the job
  -- holds no literal owner/user id and no name lookup; it resolves the owner from the steward
  -- agent's own id, which is the only uuid in the command, and that row belongs to the owner.
  begin
    select count(*) into n from cron.job c
     where c.jobname = 'crm-steward-daily' and c.active and c.schedule = '20 10 * * *' and c.database = 'postgres'
       and c.command ~* 'set local role authenticated'
       and c.command ~ 'set_config\(''request\.jwt\.claims'''
       and c.command ~ 'crm_steward_scheduled\(''daily''\)'
       and c.command ~* '^\s*do\s'
       and position(ub::text in lower(c.command)) = 0                                   -- no literal owner id
       and not exists (select 1 from auth.users u where position(u.id::text in lower(c.command)) > 0)  -- no user id at all
       and c.command !~* '\mname\M'                                                     -- no name lookup
       and c.command ~ ('a\.id = ''' || aid::text || '''')                              -- pinned to the steward agent id
       and (select array_agg(distinct x[1]) from regexp_matches(lower(c.command),
              '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'g') x) = array[aid::text]
       and (select a.user_id from public.agents a where a.id = aid) = ub;
    select count(*) into m from cron.job c where c.command ~* 'crm_steward_run';
    select count(*) into k from cron.job c where c.jobname = 'crm-steward-daily';
    r := r || jsonb_build_object('TC-SB576-8', case
           when n = 1 and m = 0 and k = 1 then 'pass'
           else format('FAIL: job ok %s, jobs named %s, jobs calling crm_steward_run %s', n, k, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-9: agent pipeline checklist (13 items) and links
  begin
    msg := '';
    with a as (select * from public.agents where id = aid)
    select concat_ws(',',
      case when not exists (select 1 from a where status = 'active') then '1-status' end,
      case when not exists (select 1 from a where meta->>'tier' in ('apex','system','management','execution')) then '2-tier' end,
      case when not exists (select 1 from a where coalesce(trim(meta->>'role'), '') <> '') then '3-role' end,
      case when not exists (select 1 from a where coalesce(trim(meta->>'domain'), '') <> '') then '4-domain' end,
      case when not exists (select 1 from a where jsonb_typeof(meta->'capabilities') = 'array' and jsonb_array_length(meta->'capabilities') > 0) then '5-capabilities' end,
      case when not exists (select 1 from a join public.agents pm on pm.name = a.meta->>'pm_assigned' and pm.status = 'active') then '6-pm' end,
      case when not exists (select 1 from a where (meta->>'escalation_path_defined')::boolean) then '7-escalation' end,
      case when not exists (select 1 from a where meta->>'onboarded_date' ~ '^\d{4}-\d{2}-\d{2}$' and (meta->>'onboarded_date')::date <= current_date) then '8-onboarded' end,
      case when not exists (select 1 from a where meta->>'file_path' like '/Users/Jason/Library/CloudStorage/CloudMounter-JasonPaulsen/AI/Skills/execution/crm-data-steward/SKILL.md') then '9-file_path' end,
      case when not exists (select 1 from public.skills s where s.skill_id = 'crm-data-steward' and not s.archived
                              and md5(s.content) = skill_md5 and s.category = 'system' and s.user_id = ub
                              and (select meta->>'file_path' from a) like '%' || s.source_path) then '10-skill_md' end,
      case when not exists (select 1 from public.agent_projects ap where ap.agent_id = aid and ap.project_id = sb and ap.role = 'worker') then '11-project' end,
      case when (select count(*) from public.agent_skills x join public.skills s on s.id = x.skill_id
                  where x.agent_id = aid and s.skill_id in ('crm-data-steward', 'sys-kanban-ticket')) <> 2 then '12-skills' end,
      case when not exists (select 1 from a join public.agents pm on pm.name = a.meta->>'pm_assigned'
                             join public.agent_projects pp on pp.agent_id = pm.id and pp.project_id = sb) then '13-pm_roster' end,
      case when not exists (select 1 from a join public.agents j on j.id = a.reports_to_agent_id
                             where j.name like 'JARVIS%' and j.status = 'active') then 'reports_to' end,
      case when exists (select 1 from a where automation_enabled) then 'automation_on' end,
      case when (select count(*) from public.agents where name = 'CRM Data Steward') <> 1 then 'agent_count' end
    ) into msg;
    r := r || jsonb_build_object('TC-SB576-9', case when coalesce(msg, '') = '' then 'pass' else 'FAIL: missing ' || msg end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-9', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-10: onboarding audit views
  begin
    select count(*) into n from public.vw_agent_onboarding_violations where agent_id = aid;
    select count(*) into m from public.vw_agent_onboarding_gaps where agent_id = aid;
    select count(*) into k from public.agent_escalation_path where agent_id = aid and reaches_a_person;
    r := r || jsonb_build_object('TC-SB576-10', case
           when n = 0 and m = 0 and k = 1 then 'pass'
           else format('FAIL: violations %s gaps %s reaches_a_person %s', n, m, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-10', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-11: deployed body = repo migration, no duration_ms write
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.crm_steward_scheduled(text)'::regprocedure
       and md5(p.prosrc) = fn_md5 and p.prosrc !~ 'duration_ms' and p.prosrc !~* 'security definer';
    select count(*) into m from pg_attribute
     where attrelid = 'public.agent_runs'::regclass and attname = 'duration_ms' and attgenerated = 's';
    r := r || jsonb_build_object('TC-SB576-11', case
           when n = 1 and m = 1 then 'pass' else format('FAIL: body match %s, duration_ms generated %s', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB576-11', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB576-12: the job always runs as the steward's owner
  -- Regression for D1. The job's owner lookup runs as postgres (no RLS). Before the fix it took the
  -- OLDEST agent named "CRM Data Steward" of ANY user, and users_insert_own lets any signed-in user
  -- insert an agent with that name and any created_at. Fixture: such an agent for another existing
  -- auth user (id not reported), status active, automation off, created before the owner's.
  begin
    begin
      reset role;
      select u.id into other from auth.users u where u.id <> ub order by u.created_at limit 1;
      if other is null then raise exception 'precondition: no second auth user'; end if;
      insert into public.agents (user_id, name, description, system_prompt, status, automation_enabled, created_at, meta)
        values (other, 'CRM Data Steward', 'qa-sb576 fixture', 'qa-sb576 fixture prompt', 'active', false,
                (select created_at - interval '1 day' from public.agents where id = aid),
                '{"qa_fixture": true}'::jsonb)
        returning id into fx;
      update public.agents set automation_enabled = true where id = aid and status = 'active';
      select count(*) into runs0 from public.agent_runs where agent_id = aid;
      execute cmd;
      uid := auth.uid();
      reset role;
      select count(*) into runs1 from public.agent_runs where agent_id = aid;
      r := r || jsonb_build_object('TC-SB576-12', case
             when uid = ub and runs1 = runs0 + 1 then 'pass'
             else format('FAIL: with an older same-name agent of another user the job ran as %s and wrote %s owner runs (expected owner, 1)',
                         case when uid = ub then 'the owner' when uid = other then 'the OTHER user' else 'nobody' end, runs1 - runs0) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB576-12', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB576-13: steward agent row missing -> the job does nothing
  -- With the owner resolved from the agent id, a missing agent row gives a null sub. The job must
  -- not run as anyone and must write nothing. Raising (42501, visible in cron.job_run_details) is
  -- accepted as fail-closed; the sqlstate is reported as evidence.
  begin
    begin
      reset role;
      select count(*) into runs0 from public.agent_runs where trigger_type = 'scheduled' and run_metadata->>'source' = 'crm_steward_scheduled';
      select count(*) into dec0 from public.crm_steward_decisions;
      delete from public.agents where id = aid;
      st := 'no error'; uid := null;
      begin
        execute cmd;
        uid := auth.uid();
      exception when others then
        st := sqlstate;
      end;
      reset role;
      select count(*) into runs1 from public.agent_runs where trigger_type = 'scheduled' and run_metadata->>'source' = 'crm_steward_scheduled';
      select count(*) into dec1 from public.crm_steward_decisions;
      r := r || jsonb_build_object('TC-SB576-13', case
             when runs1 = runs0 and dec1 = dec0 and uid is null and st in ('42501', 'no error')
             then 'pass' else format('FAIL: job %s uid_set %s scheduled runs %s->%s decisions %s->%s',
                                     st, uid is not null, runs0, runs1, dec0, dec1) end);
      r := r || jsonb_build_object('TC-SB576-13.evidence', format('agent row absent: job ended with %s, scheduled runs %s->%s, decisions %s->%s',
                                     st, runs0, runs1, dec0, dec1));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB576-13', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
  end;

  reset role;
  if exists (select 1 from public.agents where id = aid and automation_enabled) then
    r := r || jsonb_build_object('GUARD', 'FAIL: automation_enabled left true inside the suite');
  end if;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-STEWARD-SCHEDULE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'CRM-STEWARD-SCHEDULE FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
