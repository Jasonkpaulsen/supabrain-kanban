-- SB-576 fix: agent_runs.duration_ms is a generated column (finished_at - started_at), so the
-- scheduled wrapper must not write it. Found by the builder smoke test before automation was
-- switched on; no run had happened. Same function otherwise (ADR-CRM-006 §4.2, SB-576 amendment).

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

  insert into public.agent_runs (user_id, agent_id, project_id, started_at, finished_at,
                                 status, trigger_type, result_summary, error_message, error_code, run_metadata)
  values (v_uid, v_agent.id,
          (select ap.project_id from public.agent_projects ap where ap.agent_id = v_agent.id order by ap.assigned_at limit 1),
          v_start, clock_timestamp(),
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

do $chk$
begin
  if exists (select 1 from pg_proc where oid = 'public.crm_steward_scheduled(text)'::regprocedure
              and (prosecdef or not proconfig @> array['search_path=""'] or prosrc ~ 'duration_ms'))
     or has_function_privilege('anon', 'public.crm_steward_scheduled(text)', 'execute') then
    raise exception 'A1: crm_steward_scheduled must be SECURITY INVOKER, pinned, closed to anon, and not write duration_ms';
  end if;
end $chk$;
