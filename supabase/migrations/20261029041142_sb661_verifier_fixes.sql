-- SB-661 verifier fixes (2026-10-29).
--
-- 1. tz is validated: a registry row with an unknown time zone made log_scheduled_run_start fail at
--    `at time zone`, so the task could not log and the job later showed as "missing" with no hint why.
-- 2. log_scheduled_run_start records agent_inactive when the job's agent is not active. It does not
--    refuse: refusing would silence telemetry for a job that is still running.
-- 3. log_scheduled_run_finish requires every run_metadata.tickets entry to be a string (a ticket code).
-- 4. cron_health_check's connector note reads as separate from the "all clear" verdict.

create function public.scheduled_job_registry_validate()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names t where t.name = new.tz) then
    raise exception 'SB-661: unknown time zone % for scheduled job %', new.tz, new.job;
  end if;
  return new;
end
$function$;

create trigger scheduled_job_registry_validate before insert or update of tz on public.scheduled_job_registry
  for each row execute function public.scheduled_job_registry_validate();

create or replace function public.log_scheduled_run_start(p_job text, p_agent_id uuid default null,
                                                          p_trigger_id text default null, p_host text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path to ''
as $function$
declare
  r       public.scheduled_job_registry;
  v_agent uuid;
  v_user  uuid;
  v_astat text;
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
  select a.user_id, a.status into v_user, v_astat from public.agents a where a.id = v_agent;
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
            'trigger_mismatch', p_trigger_id is not null and p_trigger_id is distinct from r.trigger_id,
            'agent_inactive', v_astat is distinct from 'active'))
  returning id into v_id;
  return v_id;
end
$function$;

create or replace function public.log_scheduled_run_finish(p_run_id uuid, p_status text, p_summary text default null,
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
  if p_meta ? 'tickets' and (jsonb_typeof(p_meta->'tickets') <> 'array'
       or exists (select 1 from jsonb_array_elements(p_meta->'tickets') e where jsonb_typeof(e) <> 'string')) then
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
                           - array['registry_job', 'job', 'trigger_id', 'host', 'slot', 'tz', 'host_mismatch',
                                   'trigger_mismatch', 'agent_inactive'])
   where r.id = p_run_id
     and r.status = 'running'
     and r.run_metadata ? 'registry_job'
  returning r.id into v_id;
  return v_id is not null;
end
$function$;

revoke all on function public.log_scheduled_run_start(text, uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.log_scheduled_run_finish(uuid, text, text, int, int, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.scheduled_job_registry_validate() from public, anon, authenticated, service_role;

do $$
declare v_def text := pg_get_functiondef('public.cron_health_check()'::regprocedure);
begin
  if position('then format('' Connector standard: %s task(s) declared off-standard.''' in v_def) = 0 then
    raise exception 'SB-661: cron_health_check connector clause not found';
  end if;
  v_def := replace(v_def, 'then format('' Connector standard: %s task(s) declared off-standard.''',
                          'then format('' Separately, connector standard: %s cloud/Mac task(s) declared off-standard (SB-657).''');
  execute v_def;
end $$;

do $$
begin
  if exists (select 1 from public.scheduled_job_registry g
              where not exists (select 1 from pg_catalog.pg_timezone_names t where t.name = g.tz)) then
    raise exception 'SB-661: a seeded registry row has an unknown time zone';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname = 'public' and p.proname in ('log_scheduled_run_start', 'log_scheduled_run_finish')
                and (not p.prosecdef or p.proconfig is distinct from array['search_path=""']
                     or has_function_privilege('authenticated', p.oid, 'EXECUTE')
                     or has_function_privilege('service_role', p.oid, 'EXECUTE'))) then
    raise exception 'SB-661: scheduled-run function grants or definer config are wrong';
  end if;
end $$;
