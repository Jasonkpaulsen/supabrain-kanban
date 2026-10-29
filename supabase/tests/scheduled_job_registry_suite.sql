-- SB-661 / SB-677: scheduled_job_registry, log_scheduled_run_start/finish, agent_runs_registry_job_no_ticket
-- and the registry section of cron_health_check().
--
-- One DO block that always raises at the end, so every fixture (registry rows, agent_runs rows, the
-- activity_log row cron_health_check writes) is rolled back. Run as postgres (SQL editor or the
-- custom connector). The result is the exception text: "SCHEDULED_JOB_REGISTRY PASS (n checks) {...}".
--
-- Client-role checks catch the error inline: functions created by postgres grant no EXECUTE to
-- client roles (SB-488), so a pg_temp helper would itself fail with 42501.
do $suite$
declare
  r jsonb := '{}'::jsonb; fails int; st text; ok boolean; n int;
  v_run uuid; v_run2 uuid; v_old uuid; v_young uuid; v_fail uuid; v_ticket uuid; hc jsonb;
  role_name text; q text;
  pm constant uuid := '056e5d28-9be8-4008-8117-2802bf7a61bd';
begin
  -- fixtures: one wired job overdue, one wired job with a fresh run, one unwired job, one disabled job
  insert into public.scheduled_job_registry (job, name, host, trigger_id, schedule, agent_id, expected_runs_per_day,
         max_gap_hours, telemetry, connectors, owner, monitor_from)
  values ('qa-sb661-overdue', 'qa fixture', 'cloud', 'trig_qaSB661a', '0 1 * * *', pm, 1, 26, 'agent_runs',
          array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain QA', now() - interval '3 days'),
         ('qa-sb661-fresh', 'qa fixture', 'cloud', 'trig_qaSB661b', '0 2 * * *', pm, 1, 26, 'agent_runs',
          array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain QA', now() - interval '3 days'),
         ('qa-sb661-unwired', 'qa fixture', 'cloud', 'trig_qaSB661c', '0 3 * * *', pm, 1, 26, 'pending',
          array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain QA', now() - interval '3 days'),
         ('qa-sb661-young', 'qa fixture', 'cloud', 'trig_qaSB661d', '0 4 * * *', pm, 1, 26, 'agent_runs',
          array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain QA', now() - interval '1 hour');
  insert into public.scheduled_job_registry (job, name, host, trigger_id, schedule, agent_id, expected_runs_per_day,
         max_gap_hours, owner, enabled)
  values ('qa-sb661-disabled', 'qa fixture', 'cloud', 'trig_qaSB661e', '0 5 * * *', pm, 1, 26, 'SupaBrain QA', false);

  -- TC-SB661-1: start/finish round trip
  v_run := public.log_scheduled_run_start('qa-sb661-fresh', null, 'trig_qaSB661b', 'cloud');
  r := r || jsonb_build_object('TC-SB661-1.start_row', case
         when (select status = 'running' and work_item_id is null and trigger_type = 'scheduled' and agent_id = pm
                      and finished_at is null
                      and run_metadata->>'registry_job' = 'qa-sb661-fresh' and run_metadata->>'host' = 'cloud'
                      and run_metadata->>'trigger_id' = 'trig_qaSB661b' and run_metadata ? 'slot'
                      and (run_metadata->>'host_mismatch')::boolean = false
                      and (run_metadata->>'trigger_mismatch')::boolean = false
                 from public.agent_runs where id = v_run)
         then 'pass' else 'FAIL' end);
  v_ticket := (select id from public.work_items where ticket_code = 'SB-661');
  ok := public.log_scheduled_run_finish(v_run, 'completed', 'qa round trip', 2, 3,
          jsonb_build_object('tickets', jsonb_build_array('SB-661'), 'registry_job', 'forged', 'host', 'mac', 'note', 'kept'));
  r := r || jsonb_build_object('TC-SB661-1.finish_row', case
         when ok and (select status = 'completed' and finished_at is not null and result_summary = 'qa round trip'
                             and items_created = 2 and items_updated = 3 and work_item_id is null
                             and run_metadata->>'registry_job' = 'qa-sb661-fresh' and run_metadata->>'host' = 'cloud'
                             and run_metadata->'tickets' = '["SB-661"]'::jsonb and run_metadata->>'note' = 'kept'
                        from public.agent_runs where id = v_run)
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-1.finish_once', case
         when public.log_scheduled_run_finish(v_run, 'failed', 'second close') is false
              and (select status from public.agent_runs where id = v_run) = 'completed'
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-1.finish_ignores_other_rows', case
         when public.log_scheduled_run_finish(gen_random_uuid(), 'completed') is false then 'pass' else 'FAIL' end);
  v_run2 := public.log_scheduled_run_start('qa-sb661-fresh', null, 'trig_other', 'mac');
  r := r || jsonb_build_object('TC-SB661-1.mismatch_flags', case
         when (select (run_metadata->>'host_mismatch')::boolean and (run_metadata->>'trigger_mismatch')::boolean
                 from public.agent_runs where id = v_run2)
         then 'pass' else 'FAIL' end);

  -- refusals
  st := '';
  foreach q in array array[
      $q$select public.log_scheduled_run_start('qa-sb661-nope')$q$,
      $q$select public.log_scheduled_run_start('qa-sb661-disabled')$q$,
      $q$select public.log_scheduled_run_start('qa-sb661-fresh', null, null, 'laptop')$q$,
      format($q$select public.log_scheduled_run_finish(%L, 'done')$q$, v_run2),
      format($q$select public.log_scheduled_run_finish(%L, null)$q$, v_run2),
      format($q$select public.log_scheduled_run_finish(%L, 'completed', null, null, null, '[1]'::jsonb)$q$, v_run2),
      format($q$select public.log_scheduled_run_finish(%L, 'completed', null, null, null, '{"tickets": "SB-1"}'::jsonb)$q$, v_run2)] loop
    begin
      execute q; st := st || 'ok,';
    exception when others then st := st || case when sqlerrm like 'SB-661:%' then 'SB-661' else sqlstate end || ',';
    end;
  end loop;
  r := r || jsonb_build_object('TC-SB661-1.refusals', case
         when st = 'SB-661,SB-661,SB-661,SB-661,SB-661,SB-661,SB-661,'
              and (select status from public.agent_runs where id = v_run2) = 'running'
         then 'pass' else 'FAIL: ' || st end);

  -- TC-SB661-2: a registry row can never carry a ticket
  st := '';
  begin
    insert into public.agent_runs (user_id, agent_id, work_item_id, status, trigger_type, run_metadata)
    values ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', pm, v_ticket, 'running', 'scheduled', '{"registry_job": "qa-sb661-fresh"}');
    st := st || 'ok,';
  exception when others then st := st || sqlstate || ',';
  end;
  begin
    update public.agent_runs set work_item_id = v_ticket where id = v_run2;
    st := st || 'ok';
  exception when others then st := st || sqlstate;
  end;
  r := r || jsonb_build_object('TC-SB661-2.no_ticket_check', case
         when st = '23514,23514' and (select pg_get_constraintdef(oid) from pg_constraint
                                       where conname = 'agent_runs_registry_job_no_ticket')
                                     = 'CHECK (((NOT (run_metadata ? ''registry_job''::text)) OR (work_item_id IS NULL)))'
         then 'pass' else 'FAIL: ' || st end);
  begin
    insert into public.agent_runs (user_id, agent_id, work_item_id, status, trigger_type, run_metadata)
    values ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', pm, v_ticket, 'running', 'scheduled', '{}') returning id into v_old;
    ok := true;
  exception when others then ok := false;
  end;
  r := r || jsonb_build_object('TC-SB661-2.agent_runner_rows_unaffected', case when ok then 'pass' else 'FAIL' end);
  -- (the row above is agent-runner shaped; it is rolled back with the rest)

  -- TC-SB661-3: agent-runner's guard (select work_item_id from agent_runs where work_item_id is not null)
  -- never sees a ticket named only in run_metadata.tickets
  r := r || jsonb_build_object('TC-SB661-3.guard_unaffected', case
         when not exists (select 1 from public.agent_runs
                           where work_item_id is not null and run_metadata ? 'registry_job')
              and (select count(*) from public.agent_runs where run_metadata->'tickets' ? 'SB-661' and work_item_id is null) >= 1
         then 'pass' else 'FAIL' end);

  -- TC-SB661-4 / 5: health check
  v_old := public.log_scheduled_run_start('qa-sb661-fresh');
  update public.agent_runs set started_at = now() - interval '3 hours' where id = v_old;
  v_young := public.log_scheduled_run_start('qa-sb661-fresh');
  update public.agent_runs set started_at = now() - interval '1 hour' where id = v_young;
  v_fail := public.log_scheduled_run_start('qa-sb661-fresh');
  ok := public.log_scheduled_run_finish(v_fail, 'failed', 'qa failure');
  hc := public.cron_health_check();
  r := r || jsonb_build_object('TC-SB661-4.missing_flagged', case
         when hc->'registry'->'missing' @> '[{"job": "qa-sb661-overdue"}]' then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-4.not_missing', case
         when not (hc->'registry'->'missing' @> '[{"job": "qa-sb661-fresh"}]')
              and not (hc->'registry'->'missing' @> '[{"job": "qa-sb661-unwired"}]')
              and not (hc->'registry'->'missing' @> '[{"job": "qa-sb661-young"}]')
              and not (hc->'registry'->'missing' @> '[{"job": "qa-sb661-disabled"}]')
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-5.stuck', case
         when hc->'registry'->'stuck' @> jsonb_build_array(jsonb_build_object('run_id', v_old))
              and not (hc->'registry'->'stuck' @> jsonb_build_array(jsonb_build_object('run_id', v_young)))
              and not (hc->'registry'->'stuck' @> jsonb_build_array(jsonb_build_object('run_id', v_run2)))
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-5.failed', case
         when hc->'registry'->'failed' @> jsonb_build_array(jsonb_build_object('run_id', v_fail, 'status', 'failed'))
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-4.summary_and_log', case
         when hc->>'summary' like '%scheduled tasks: % missing, % stuck, % failed.%'
              and hc ? 'failures' and hc ? 'silent_jobs'
              and exists (select 1 from public.activity_log where target_table = 'cron_health'
                            and meta ? 'registry' and created_at > now() - interval '1 minute')
         then 'pass' else 'FAIL: ' || coalesce(hc->>'summary', 'null') end);
  r := r || jsonb_build_object('TC-SB661-4.off_standard_declared', case
         when hc->'registry'->'off_standard_connectors' @> '[{"job": "dev-heartbeat"}]'
              and not (hc->'registry'->'off_standard_connectors' @> '[{"job": "pm-triage"}]')
         then 'pass' else 'FAIL' end);

  -- seed and shape
  r := r || jsonb_build_object('TC-SB661-seed', case
         when (select count(*) from public.scheduled_job_registry where job not like 'qa-sb661-%') = 30
              and (select count(*) from public.scheduled_job_registry where host = 'pg_cron' and telemetry = 'cron') = 15
              and not exists (select 1 from public.scheduled_job_registry where job not like 'qa-sb661-%' and telemetry = 'agent_runs')
              and not exists (select 1 from public.scheduled_job_registry g where g.host = 'pg_cron'
                               and not exists (select 1 from cron.job j where j.jobname = g.cron_jobname and j.active))
              and (select count(*) from cron.job where active) = 15
         then 'pass' else 'FAIL' end);
  st := '';
  foreach q in array array[
      $q$insert into public.scheduled_job_registry (job, name, host, schedule, expected_runs_per_day, max_gap_hours, owner) values ('qa-sb661-x1', 'x', 'cloud', '* * * * *', 1, 1, 'qa')$q$,
      $q$insert into public.scheduled_job_registry (job, name, host, cron_jobname, schedule, expected_runs_per_day, max_gap_hours, owner, telemetry) values ('qa-sb661-x2', 'x', 'pg_cron', 'j', '* * * * *', 1, 1, 'qa', 'agent_runs')$q$,
      $q$insert into public.scheduled_job_registry (job, name, host, trigger_id, schedule, expected_runs_per_day, max_gap_hours, owner, telemetry) values ('qa-sb661-x3', 'x', 'cloud', 'trig_x', '* * * * *', 1, 1, 'qa', 'cron')$q$,
      $q$insert into public.scheduled_job_registry (job, name, host, trigger_id, schedule, expected_runs_per_day, max_gap_hours, owner) values ('QA bad', 'x', 'cloud', 'trig_x', '* * * * *', 1, 1, 'qa')$q$,
      $q$insert into public.scheduled_job_registry (job, name, host, trigger_id, schedule, expected_runs_per_day, max_gap_hours, owner) values ('qa-sb661-x5', 'x', 'cloud', 'trig_x', '* * * * *', 0, 1, 'qa')$q$] loop
    begin
      execute q; st := st || 'ok,';
    exception when others then st := st || sqlstate || ',';
    end;
  end loop;
  r := r || jsonb_build_object('TC-SB661-shape_checks', case
         when st = '23514,23514,23514,23514,23514,' then 'pass' else 'FAIL: ' || st end);

  -- access: client roles cannot read the registry or call the functions; service_role cannot call them
  foreach role_name in array array['anon', 'authenticated', 'service_role'] loop
    st := '';
    execute format('set local role %I', role_name);
    foreach q in array array[
        'select count(*) from public.scheduled_job_registry',
        $q$select public.log_scheduled_run_start('qa-sb661-fresh')$q$,
        format($q$select public.log_scheduled_run_finish(%L, 'completed')$q$, v_run2)] loop
      begin
        execute q; st := st || 'ok,';
      exception when others then st := st || sqlstate || ',';
      end;
    end loop;
    execute 'reset role';
    r := r || jsonb_build_object('TC-SB661-access.' || role_name, case
           when role_name <> 'service_role' and st = '42501,42501,42501,' then 'pass'
           when role_name = 'service_role' and st in ('ok,42501,42501,') then 'pass'
           else 'FAIL: ' || st end);
  end loop;
  r := r || jsonb_build_object('TC-SB661-access.still_running', case
         when (select status from public.agent_runs where id = v_run2) = 'running' then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB661-definer_config', case
         when (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                where s.nspname = 'public' and p.proname in ('log_scheduled_run_start', 'log_scheduled_run_finish')
                  and p.prosecdef and p.proconfig = array['search_path=""']) = 2
              and (select relrowsecurity from pg_class where oid = 'public.scheduled_job_registry'::regclass)
              and (select array_agg(policyname || ':' || permissive) from pg_policies
                    where schemaname = 'public' and tablename = 'scheduled_job_registry') = array['oauth_client_deny:RESTRICTIVE']
         then 'pass' else 'FAIL' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'SCHEDULED_JOB_REGISTRY PASS (% checks) %', (select count(*) from jsonb_object_keys(r)), r;
  else
    raise exception 'SCHEDULED_JOB_REGISTRY FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)), r;
  end if;
end
$suite$;
