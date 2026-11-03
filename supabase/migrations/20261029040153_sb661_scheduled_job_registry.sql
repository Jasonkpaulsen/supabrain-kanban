-- SB-661 (WP3 of the SB-656 scheduled-jobs redesign): a registry of what should run, and outcome rows
-- for the LLM scheduled tasks, which today leave none (0 of ~100 runs a week).
--
-- 1. scheduled_job_registry: one row per scheduled job (cloud task, Mac task, pg_cron job, launchd
--    agent). `telemetry` says how a run is observed: 'agent_runs' (the task calls
--    log_scheduled_run_start/finish), 'cron' (cron.job_run_details, which cron_health_check already
--    reads) or 'pending' (not wired yet). WP1, WP4-WP8 and WP12 add the start/finish lines to each
--    task and then set telemetry = 'agent_runs' and monitor_from = now(). Only 'agent_runs' jobs can be
--    reported missing, so a job that is not wired yet is never a false alarm.
-- 2. log_scheduled_run_start / log_scheduled_run_finish write agent_runs rows with work_item_id NULL.
--    agent-runner's once-per-ticket guard skips any ticket that has any agent_runs row, so a
--    scheduled-run row naming a ticket would silently stop plan dispatch for it. Tickets a run touched
--    go in run_metadata.tickets[] instead.
-- 3. agent_runs_registry_job_no_ticket enforces that: a row carrying run_metadata.registry_job never
--    has a work_item_id. agent-runner's own rows carry no registry_job and are unaffected.
-- 4. cron_health_check() (P07) also compares the registry with agent_runs: missing (no run within
--    max_gap_hours), stuck (running for more than 2 h) and failed (failed or timed out in 24 h), and
--    lists cloud/Mac jobs whose declared connectors are off the SB-657 standard.

create table public.scheduled_job_registry (
  id                    uuid primary key default gen_random_uuid(),
  job                   text not null unique check (job ~ '^[a-z0-9][a-z0-9-]*$'),
  name                  text not null,
  host                  text not null check (host in ('cloud', 'mac', 'pg_cron', 'launchd')),
  trigger_id            text check (trigger_id ~ '^trig_[A-Za-z0-9]+$'),
  cron_jobname          text,
  schedule              text not null,
  tz                    text not null default 'UTC',
  agent_id              uuid references public.agents(id),
  expected_runs_per_day numeric not null check (expected_runs_per_day > 0),
  max_gap_hours         numeric not null check (max_gap_hours > 0),
  telemetry             text not null default 'pending' check (telemetry in ('pending', 'agent_runs', 'cron')),
  connectors            text[] not null default '{}',
  enabled               boolean not null default true,
  owner                 text not null,
  monitor_from          timestamptz not null default now(),
  notes                 text,
  meta                  jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint scheduled_job_registry_host_ids check (
       (host in ('cloud', 'mac') and trigger_id is not null and cron_jobname is null)
    or (host = 'pg_cron' and cron_jobname is not null and trigger_id is null)
    or (host = 'launchd' and trigger_id is null and cron_jobname is null)),
  constraint scheduled_job_registry_cron_telemetry check (telemetry <> 'cron' or host = 'pg_cron'),
  constraint scheduled_job_registry_agent_for_runs check (telemetry <> 'agent_runs' or agent_id is not null)
);

comment on table public.scheduled_job_registry is
  'SB-661: what should run. telemetry=agent_runs jobs are checked by cron_health_check for missing/stuck/failed runs.';

create trigger trigger_update_updated_at before update on public.scheduled_job_registry
  for each row execute function public.update_updated_at();

alter table public.scheduled_job_registry enable row level security;
revoke all on table public.scheduled_job_registry from anon, authenticated;

-- SB-595 convention, created explicitly: the event trigger does not fire in every apply path (SB-650).
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'scheduled_job_registry'
                  and policyname = 'oauth_client_deny') then
    execute 'create policy oauth_client_deny on public.scheduled_job_registry as restrictive for all to authenticated '
         || 'using ((select public.oauth_client_id()) is null) with check ((select public.oauth_client_id()) is null)';
  end if;
end $$;

alter table public.agent_runs add constraint agent_runs_registry_job_no_ticket
  check (not (run_metadata ? 'registry_job') or work_item_id is null);

create index agent_runs_registry_job_idx on public.agent_runs ((run_metadata->>'registry_job'), started_at)
  where run_metadata ? 'registry_job';

create function public.log_scheduled_run_start(p_job text, p_agent_id uuid default null,
                                               p_trigger_id text default null, p_host text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  r      public.scheduled_job_registry;
  v_agent uuid;
  v_user  uuid;
  v_host  text;
  v_id    uuid;
begin
  select * into r from public.scheduled_job_registry j where j.job = p_job;
  if not found then
    raise exception 'SB-661: unknown scheduled job %', p_job;
  end if;
  if not r.enabled then
    raise exception 'SB-661: scheduled job % is disabled in the registry', p_job;
  end if;
  v_agent := coalesce(p_agent_id, r.agent_id);
  select a.user_id into v_user from public.agents a where a.id = v_agent;
  if v_user is null then
    raise exception 'SB-661: scheduled job % has no agent (pass p_agent_id or set the registry agent_id)', p_job;
  end if;
  v_host := coalesce(p_host, r.host);
  if v_host not in ('cloud', 'mac', 'pg_cron', 'launchd') then
    raise exception 'SB-661: host must be cloud, mac, pg_cron or launchd (got %)', v_host;
  end if;
  insert into public.agent_runs (user_id, agent_id, work_item_id, status, trigger_type, run_metadata)
  values (v_user, v_agent, null, 'running', 'scheduled', jsonb_build_object(
            'registry_job', r.job,
            'job', r.job,
            'trigger_id', coalesce(p_trigger_id, r.trigger_id),
            'host', v_host,
            'slot', to_char(now() at time zone r.tz, 'YYYY-MM-DD"T"HH24:MI'),
            'tz', r.tz,
            'host_mismatch', v_host <> r.host,
            'trigger_mismatch', p_trigger_id is not null and p_trigger_id is distinct from r.trigger_id))
  returning id into v_id;
  return v_id;
end
$function$;

create function public.log_scheduled_run_finish(p_run_id uuid, p_status text, p_summary text default null,
                                                p_items_created int default null, p_items_updated int default null,
                                                p_meta jsonb default '{}'::jsonb)
returns boolean
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  v_id uuid;
begin
  if p_status is null or p_status not in ('completed', 'failed', 'timeout', 'cancelled') then
    raise exception 'SB-661: status must be completed, failed, timeout or cancelled (got %)', p_status;
  end if;
  if p_meta is not null and jsonb_typeof(p_meta) <> 'object' then
    raise exception 'SB-661: p_meta must be a JSON object';
  end if;
  if p_meta ? 'tickets' and jsonb_typeof(p_meta->'tickets') <> 'array' then
    raise exception 'SB-661: p_meta.tickets must be an array of ticket codes';
  end if;
  -- duration_ms and tokens_total are generated columns: never written here.
  update public.agent_runs r
     set finished_at   = now(),
         status        = p_status,
         result_summary = left(p_summary, 4000),
         error_message = case when p_status = 'completed' then r.error_message else left(p_summary, 4000) end,
         items_created = p_items_created,
         items_updated = p_items_updated,
         run_metadata  = r.run_metadata || (coalesce(p_meta, '{}'::jsonb)
                           - array['registry_job', 'job', 'trigger_id', 'host', 'slot', 'tz', 'host_mismatch', 'trigger_mismatch'])
   where r.id = p_run_id
     and r.status = 'running'
     and r.run_metadata ? 'registry_job'
  returning r.id into v_id;
  return v_id is not null;
end
$function$;

revoke all on function public.log_scheduled_run_start(text, uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.log_scheduled_run_finish(uuid, text, text, int, int, jsonb) from public, anon, authenticated, service_role;

create or replace function public.cron_health_check()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_failures jsonb;
  v_stale jsonb;
  v_missing jsonb;
  v_stuck jsonb;
  v_run_failed jsonb;
  v_off_standard jsonb;
  v_registry jsonb;
  v_summary text;
begin
  -- Failed runs in the last 24h
  select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'at', d.end_time, 'error', left(d.return_message, 200)) order by d.end_time desc), '[]'::jsonb)
    into v_failures
  from cron.job_run_details d join cron.job j on j.jobid=d.jobid
  where d.end_time > now() - interval '24 hours' and d.status = 'failed';

  -- Active jobs that have not run at all in the last 25h (scheduler-dead detection).
  -- Catches the failure mode a failure-log check misses: a job that silently stopped firing.
  select coalesce(jsonb_agg(jsonb_build_object('job', j.jobname, 'schedule', j.schedule)), '[]'::jsonb)
    into v_stale
  from cron.job j
  where j.active
    and not exists (select 1 from cron.job_run_details d
                    where d.jobid=j.jobid and d.start_time > now() - interval '25 hours');

  -- SB-661: scheduled tasks that report through agent_runs (scheduled_job_registry.telemetry = 'agent_runs').
  select coalesce(jsonb_agg(jsonb_build_object('job', g.job, 'host', g.host, 'max_gap_hours', g.max_gap_hours,
           'last_run', (select max(r.started_at) from agent_runs r where r.run_metadata->>'registry_job' = g.job))
           order by g.job), '[]'::jsonb)
    into v_missing
  from scheduled_job_registry g
  where g.enabled and g.telemetry = 'agent_runs'
    and g.monitor_from < now() - g.max_gap_hours * interval '1 hour'
    and not exists (select 1 from agent_runs r
                    where r.run_metadata->>'registry_job' = g.job
                      and r.started_at > now() - g.max_gap_hours * interval '1 hour');

  select coalesce(jsonb_agg(jsonb_build_object('job', r.run_metadata->>'registry_job', 'run_id', r.id, 'started_at', r.started_at)
           order by r.started_at), '[]'::jsonb)
    into v_stuck
  from agent_runs r
  where r.run_metadata ? 'registry_job' and r.status = 'running' and r.started_at < now() - interval '2 hours';

  select coalesce(jsonb_agg(jsonb_build_object('job', r.run_metadata->>'registry_job', 'run_id', r.id, 'status', r.status,
           'at', coalesce(r.finished_at, r.started_at), 'error', left(r.error_message, 200))
           order by coalesce(r.finished_at, r.started_at) desc), '[]'::jsonb)
    into v_run_failed
  from agent_runs r
  where r.run_metadata ? 'registry_job' and r.status in ('failed', 'timeout')
    and coalesce(r.finished_at, r.started_at) > now() - interval '24 hours';

  -- Declared state only: the live connectors are read from list_triggers by a prompt step.
  select coalesce(jsonb_agg(jsonb_build_object('job', g.job, 'host', g.host, 'connectors', g.connectors) order by g.job), '[]'::jsonb)
    into v_off_standard
  from scheduled_job_registry g
  where g.enabled and g.host in ('cloud', 'mac')
    and g.connectors is distinct from array['0be37871-004b-4f8a-8ee4-ae3313b8884b']::text[];

  v_registry := jsonb_build_object('missing', v_missing, 'stuck', v_stuck, 'failed', v_run_failed,
                                   'off_standard_connectors', v_off_standard);

  v_summary := case
    when jsonb_array_length(v_failures)=0 and jsonb_array_length(v_stale)=0
     and jsonb_array_length(v_missing)=0 and jsonb_array_length(v_stuck)=0 and jsonb_array_length(v_run_failed)=0
      then 'Cron health: all clear — every active job ran, zero failures in 24h; no scheduled task missing, stuck or failed.'
    else format('Cron health: %s failed run(s), %s silent job(s) in 24h; scheduled tasks: %s missing, %s stuck, %s failed.',
                jsonb_array_length(v_failures), jsonb_array_length(v_stale),
                jsonb_array_length(v_missing), jsonb_array_length(v_stuck), jsonb_array_length(v_run_failed))
  end
  || case when jsonb_array_length(v_off_standard) > 0
          then format(' Connector standard: %s task(s) declared off-standard.', jsonb_array_length(v_off_standard))
          else '' end;

  -- One row per day, clean or not: silence must be distinguishable from a dead monitor.
  insert into activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
          'System','commented','cron_health', v_summary,
          jsonb_build_object('artifact','cron_health','failures',v_failures,'silent_jobs',v_stale,'registry',v_registry));

  return jsonb_build_object('summary', v_summary, 'failures', v_failures, 'silent_jobs', v_stale, 'registry', v_registry);
end $function$;

-- Seed. Schedules for cloud tasks are their cron expressions (2026-10-29); Mac schedules come from the
-- 2026-10-28 catalog timeline and are confirmed in WP12. Every LLM task starts as telemetry 'pending'.
insert into public.scheduled_job_registry
  (job, name, host, trigger_id, schedule, tz, agent_id, expected_runs_per_day, max_gap_hours, connectors, owner, meta)
values
  ('pm-triage', 'Pm triage dispatch', 'cloud', 'trig_015BsnuQrzgiQzXDEByiW1J8', '15 9 * * *', 'America/New_York',
   '056e5d28-9be8-4008-8117-2802bf7a61bd', 1, 26, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain Operations PM', '{"retire_in": "WP4"}'),
  ('license-sentinel-weekly', 'Weekly license sentinel audit', 'cloud', 'trig_013FnUae3aBhtwM5L7ZjFXuS', '0 4 * * 6', 'America/New_York',
   'e9973715-e9cf-43dc-8089-83395a7449b4', 0.142857, 170, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'CIP License Sentinel', '{}'),
  ('license-sentinel-daily', 'License sentinel weekly audit (runs daily)', 'cloud', 'trig_019FjNEWbtj9d6vNcHCfFM59', '0 6 * * *', 'America/New_York',
   'e9973715-e9cf-43dc-8089-83395a7449b4', 1, 26, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'CIP License Sentinel', '{"catalog_finding": "F2"}'),
  ('management-sweep', 'Management agent sweep', 'cloud', 'trig_01HUjpypxaonzFZ6hFYsXwNX', '45 18 * * *', 'America/New_York',
   '91ed8088-5cc7-4395-a051-d26693a2f0bb', 1, 26, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain Process Engineer', '{"rewrite_in": "WP6"}'),
  ('pe-daily', 'Process engineer daily', 'cloud', 'trig_01A17mZZV7UVurH4ynUyAk4T', '0 19 * * *', 'America/New_York',
   '91ed8088-5cc7-4395-a051-d26693a2f0bb', 1, 26, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'SupaBrain Process Engineer', '{}'),
  ('school-monitor', 'School Monitor daily Classroom check', 'cloud', 'trig_01B6t5HabesrvwLbxwnBTtpH', '0 21 * * *', 'UTC',
   'fd887fac-265d-4fb6-aa2d-88d9389eac18', 1, 26, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'School & Activities Lead', '{}'),
  ('backlog-grooming-biweekly', 'Biweekly Backlog Grooming (CIP-first)', 'cloud', 'trig_019yZ8YjoKZe8zLiB3nB9cZp', '0 13 1,15 * *', 'UTC',
   '6fa6c691-ace1-4be5-99fe-2fb30f7395ae', 0.065703, 410, array['0be37871-004b-4f8a-8ee4-ae3313b8884b'], 'JARVIS — Master Orchestrator', '{}'),
  ('jarvis-morning', 'Jarvis sweep morning', 'mac', 'trig_01Y7AqZesCBmJCdN1KiFQchL', '0 7 * * *', 'America/New_York',
   '6fa6c691-ace1-4be5-99fe-2fb30f7395ae', 1, 26, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'JARVIS — Master Orchestrator', '{"schedule_source": "catalog 2026-10-28", "move_in": "WP12"}'),
  ('jarvis-midday', 'Jarvis sweep midday', 'mac', 'trig_015CmaTMccnd6KSwD4r1VSv1', '0 13 * * *', 'America/New_York',
   '6fa6c691-ace1-4be5-99fe-2fb30f7395ae', 1, 26, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'JARVIS — Master Orchestrator', '{"schedule_source": "catalog 2026-10-28", "move_in": "WP12"}'),
  ('jarvis-evening', 'Jarvis sweep evening', 'mac', 'trig_01AB1J8vmeXnceUbqGLTtHjC', '15 19 * * *', 'America/New_York',
   '6fa6c691-ace1-4be5-99fe-2fb30f7395ae', 1, 26, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'JARVIS — Master Orchestrator', '{"schedule_source": "catalog 2026-10-28", "move_in": "WP12"}'),
  ('jarvis-weekly', 'Jarvis sweep weekly', 'mac', 'trig_014JmZXVRKtGmn3VSsokpMcS', '0 9 * * 0', 'America/New_York',
   '6fa6c691-ace1-4be5-99fe-2fb30f7395ae', 0.142857, 170, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'JARVIS — Master Orchestrator', '{"move_in": "WP12"}'),
  ('lce-article-sweep', 'Lce article sweep', 'mac', 'trig_01CdjdLTnuWhfzFneUEBW6CY', '0 8 * * *', 'America/New_York',
   null, 1, 26, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'Content Editor', '{"schedule_source": "catalog 2026-10-28", "move_in": "WP12"}'),
  ('lce-image-fulfiller', 'Lce image request fulfiller', 'mac', 'trig_017bU9DRywQxjqr9Ca29YAYs', '0 9,13,18 * * *', 'America/New_York',
   null, 3, 17, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'Content Editor', '{"move_in": "WP12"}'),
  ('dev-heartbeat', 'Dev heartbeat', 'mac', 'trig_01D8gEWYcfHy1rvcQQjbLDu9', '30 8 * * *', 'America/New_York',
   null, 1, 26, array['af2943fa-04c3-4897-a7c4-a1e85a18eab2'], 'SupaBrain Operations PM', '{"schedule_source": "catalog 2026-10-28", "retire_in": "WP4"}');

insert into public.scheduled_job_registry
  (job, name, host, cron_jobname, schedule, tz, expected_runs_per_day, max_gap_hours, telemetry, owner)
select v.job, v.job, 'pg_cron', j.jobname, j.schedule, 'UTC', v.per_day, v.gap, 'cron', 'Supabase Platform Engineer'
from (values
  ('agent-runner-assign', 96, 0.75), ('agent-runner-dispatch-all', 24, 1.5), ('agent-runner-dispatch-cip', 24, 1.5),
  ('agent-runner-sweep', 1, 26), ('backlog-grooming-weekly', 0.142857, 170), ('crm-steward-daily', 1, 26),
  ('crm-steward-weekly', 0.142857, 170), ('cron-health-daily', 1, 26), ('deploy-drift-daily', 1, 26),
  ('deploy-drift-fetch', 1, 26), ('lce-daily-cleanup', 1, 26), ('qa-shiftleft-daily', 1, 26),
  ('review-sla-daily', 1, 26), ('watch-cip165-dispatch166', 480, 0.15), ('work-item-archive-sweep', 1, 26)
) v(job, per_day, gap)
join cron.job j on j.jobname = v.job and j.active;

insert into public.scheduled_job_registry
  (job, name, host, schedule, tz, agent_id, expected_runs_per_day, max_gap_hours, owner, notes)
values
  ('classroom-daily-sync', 'Classroom daily sync (Mac LaunchAgent)', 'launchd', '15 15 * * *', 'America/New_York',
   'fd887fac-265d-4fb6-aa2d-88d9389eac18', 1, 26, 'School & Activities Lead',
   'Writes its own agent_runs heartbeat (run_metadata.job = classroom-daily-sync, CLSRM-3); moving it to registry telemetry is WP12.');

do $$
declare n int;
begin
  select count(*) into n from public.scheduled_job_registry;
  if n < 30 then raise exception 'SB-661: registry seed has % rows, expected 30', n; end if;
  if exists (select 1 from public.scheduled_job_registry where telemetry = 'agent_runs') then
    raise exception 'SB-661: no job may start with telemetry agent_runs';
  end if;
  if has_table_privilege('anon', 'public.scheduled_job_registry', 'SELECT')
     or has_table_privilege('authenticated', 'public.scheduled_job_registry', 'SELECT') then
    raise exception 'SB-661: client roles can read scheduled_job_registry';
  end if;
  if has_function_privilege('anon', 'public.log_scheduled_run_start(text,uuid,text,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.log_scheduled_run_start(text,uuid,text,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.log_scheduled_run_finish(uuid,text,text,integer,integer,jsonb)', 'EXECUTE') then
    raise exception 'SB-661: client roles can execute the scheduled-run functions';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname = 'public' and p.proname in ('log_scheduled_run_start', 'log_scheduled_run_finish')
                and (not p.prosecdef or p.proconfig is distinct from array['search_path=""'])) then
    raise exception 'SB-661: a scheduled-run function lost SECURITY DEFINER or its empty search_path';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'scheduled_job_registry'
                  and policyname = 'oauth_client_deny' and permissive = 'RESTRICTIVE') then
    raise exception 'SB-661: scheduled_job_registry is missing the oauth_client_deny policy';
  end if;
end $$;
