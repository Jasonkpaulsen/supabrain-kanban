-- SB-576 (ADR-CRM-006 §4.2, as amended 2026-10-08): the CRM Data Steward's schedule.
--
-- crm_steward_scheduled(p_task) is the only thing the schedule calls. It runs as the owner
-- (SECURITY INVOKER, RLS), finds the owner's "CRM Data Steward" agent, and does nothing at all
-- while that agent is missing, not active, or has automation off. When enabled it runs the
-- steward and writes one agent_runs row (summary in run_metadata; a failure is a 'failed' run,
-- never an aborted job), then bumps last_run_at / run_count / error_count.
--
-- The pg_cron job does not call anything as postgres: inside one DO block it sets the owner's
-- claims (owner taken from the agent row; no literal id) and SET LOCAL ROLE authenticated,
-- which is what an API call with the owner's JWT gets. The command never names
-- crm_steward_run (SB-573 assertion A3 stands). Tasks: 'daily' here; SB-575/SB-574 add 'weekly'.

create or replace function public.crm_steward_scheduled(p_task text default 'daily')
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  v_agent  public.agents%rowtype;
  v_start  timestamptz := clock_timestamp();
  v_out    jsonb;
  v_state  text;
  v_err    text;
  v_note   text;
begin
  if v_uid is null then
    raise exception 'the scheduled steward needs a signed-in owner' using errcode = '42501';
  end if;
  if p_task is null or p_task not in ('daily') then
    raise exception 'unknown steward task %', coalesce(p_task, '(null)') using errcode = '22023';
  end if;
  select * into v_agent from public.agents a
   where a.user_id = v_uid and a.name = 'CRM Data Steward'
   order by a.created_at limit 1;
  if v_agent.id is null or not coalesce(v_agent.automation_enabled, false)
     or coalesce(v_agent.status, 'active') <> 'active' then
    return jsonb_build_object('task', p_task, 'skipped', true,
                              'reason', 'steward agent missing, not active, or automation off');
  end if;

  begin
    if p_task = 'daily' then
      v_out := public.crm_steward_run(false, 200);
      v_note := format('decisions %s%s; merged %s; confirmed A/B/C %s/%s/%s; conflicts kept/took/left %s/%s/%s; dismissed %s; expired %s',
        v_out->>'decisions', case when (v_out->>'capped')::boolean then ' (capped)' else '' end,
        v_out#>>'{merges,merged}',
        v_out#>>'{confirmed,tier_a}', v_out#>>'{confirmed,tier_b_14d}', v_out#>>'{confirmed,tier_c_corroborated}',
        v_out#>>'{conflicts,kept_existing}', v_out#>>'{conflicts,took_incoming}', v_out#>>'{conflicts,left_tier_a_vs_a}',
        v_out#>>'{gray_zone,dismissed}',
        coalesce((v_out#>>'{expired,facts}')::int, 0) + coalesce((v_out#>>'{expired,interactions}')::int, 0));
    end if;
    v_state := case when (v_out->>'disabled')::boolean then 'cancelled' else 'completed' end;
  exception when others then
    v_state := 'failed';
    v_err := sqlstate || ': ' || left(sqlerrm, 300);
  end;

  insert into public.agent_runs (user_id, agent_id, project_id, started_at, finished_at, duration_ms,
                                 status, trigger_type, result_summary, error_message, error_code, run_metadata)
  values (v_uid, v_agent.id,
          (select ap.project_id from public.agent_projects ap where ap.agent_id = v_agent.id order by ap.assigned_at limit 1),
          v_start, clock_timestamp(), (extract(epoch from clock_timestamp() - v_start) * 1000)::int,
          v_state, 'scheduled', coalesce(v_note, v_err, v_out::text), v_err,
          case when v_state = 'failed' then split_part(v_err, ':', 1) end,
          jsonb_build_object('task', p_task, 'summary', v_out, 'source', 'crm_steward_scheduled'));

  update public.agents
     set last_run_at = now(),
         run_count   = coalesce(run_count, 0) + 1,
         error_count = coalesce(error_count, 0) + (v_state = 'failed')::int,
         last_error  = case when v_state = 'failed' then v_err else last_error end
   where id = v_agent.id and user_id = v_uid;

  return jsonb_build_object('task', p_task, 'status', v_state, 'summary', v_out, 'error', v_err);
end $fn$;
comment on function public.crm_steward_scheduled(text) is
  'SB-576 / ADR-CRM-006 §4.2. Scheduled entry point of the CRM Data Steward: no-op unless the owner''s steward agent is active with automation on; logs one agent_runs row per run.';
revoke all on function public.crm_steward_scheduled(text) from public, anon;
grant execute on function public.crm_steward_scheduled(text) to authenticated, service_role;

-- ---------------------------------------------------------------- schedule (daily 10:20 UTC)
select cron.unschedule(jobid) from cron.job where jobname = 'crm-steward-daily';
select cron.schedule('crm-steward-daily', '20 10 * * *', $job$
do $run$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select a.user_id from public.agents a where a.name = 'CRM Data Steward'
                               order by a.created_at limit 1),
                      'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.crm_steward_scheduled('daily');
end $run$;
$job$);

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if exists (select 1 from pg_proc where oid = 'public.crm_steward_scheduled(text)'::regprocedure
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_steward_scheduled(text)', 'execute') then
    raise exception 'A1: crm_steward_scheduled must be SECURITY INVOKER, pinned, and closed to anon';
  end if;
  if not exists (select 1 from cron.job where jobname = 'crm-steward-daily' and active
                   and command ~ 'set local role authenticated' and command ~ 'crm_steward_scheduled') then
    raise exception 'A2: the daily job must exist and switch to the owner role';
  end if;
  if exists (select 1 from cron.job where command ~* 'crm_steward_run') then
    raise exception 'A3: no cron job may call crm_steward_run directly';
  end if;
end $chk$;
