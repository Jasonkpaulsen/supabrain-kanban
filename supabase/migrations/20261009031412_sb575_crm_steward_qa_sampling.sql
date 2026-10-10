-- SB-575 (ADR-CRM-006 §7): weekly QA sampling of the steward's automatic decisions, QA verdicts,
-- and automatic suspension of auto-merge when the wrong-merge rate goes above 2%.
--
-- * qa_sample: new decision type. One append-only row per sampled decision (refers_to = it).
-- * crm_steward_qa_sample(p_size): merges first (the metric is the wrong-merge rate and merges are
--   rare), then random other automatic decisions of the last 7 days; never samples a decision
--   twice; once per week (skips if a sample was taken in the last 6 days). Opens one SB ticket for
--   SupaBrain QA holding ids only (no names or values) and how to record a verdict.
-- * crm_steward_record_verdict(decision, verdict, reason): qa_verdict row on one of the owner's
--   automatic decisions; then, over the latest verdict of each of the last 50 merge decisions with a
--   verdict, writes `suspend` when wrong/count > 2% and auto-merge is not already suspended.
--   Never undoes anything (undo stays an explicit crm_unmerge).
-- * crm_steward_scheduled('weekly') runs the sampler; pg_cron crm-steward-weekly, Mon 10:40 UTC.
-- All SECURITY INVOKER (owner, RLS), search_path pinned, closed to anon.

alter table public.crm_steward_decisions drop constraint crm_steward_decisions_decision_check;
alter table public.crm_steward_decisions add constraint crm_steward_decisions_decision_check
  check (decision in ('auto_confirm', 'auto_merge', 'auto_resolve', 'auto_expire', 'auto_dismiss',
                      'suspend', 'resume', 'qa_verdict', 'qa_sample'));
create index crm_steward_decisions_refers_to
  on public.crm_steward_decisions (refers_to) where refers_to is not null;

-- ---------------------------------------------------------------- sampler
create or replace function public.crm_steward_qa_sample(p_size integer default 10)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid     uuid := auth.uid();
  v_size    int  := least(greatest(coalesce(p_size, 10), 1), 50);
  v_run     uuid := gen_random_uuid();
  v_ids     uuid[];
  v_n       int;
  v_merges  int;
  v_project uuid;
  v_epic    uuid;
  v_wi      uuid;
  v_code    text;
  v_lines   text;
begin
  if v_uid is null then
    raise exception 'QA sampling needs a signed-in owner' using errcode = '42501';
  end if;
  if exists (select 1 from public.crm_steward_decisions s
              where s.user_id = v_uid and s.decision = 'qa_sample' and s.created_at > now() - interval '6 days') then
    return jsonb_build_object('skipped', true, 'reason', 'a QA sample was already taken this week');
  end if;

  select array_agg(x.id order by x.grp, x.r) into v_ids
    from (select u.id, u.grp, u.r
            from (select d.id, case when d.decision = 'auto_merge' then 0 else 1 end as grp, random() as r
                    from public.crm_steward_decisions d
                   where d.user_id = v_uid
                     and d.decision in ('auto_confirm', 'auto_merge', 'auto_resolve', 'auto_expire', 'auto_dismiss')
                     and (d.decision = 'auto_merge' or d.created_at > now() - interval '7 days')
                     and not exists (select 1 from public.crm_steward_decisions s
                                      where s.user_id = v_uid and s.decision = 'qa_sample' and s.refers_to = d.id)) u
           order by u.grp, u.r
           limit v_size) x;
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 0 then
    return jsonb_build_object('sampled', 0, 'merges', 0, 'run_id', v_run, 'work_item', null);
  end if;

  insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id, refers_to)
  select 'qa_sample', 'weekly_sample', 'crm_steward_decisions', t.id, 'qa_sample', v_run, t.id
    from unnest(v_ids) with ordinality as t(id, ord) order by t.ord;

  select count(*) filter (where d.decision = 'auto_merge'),
         string_agg(format('- `%s` · %s · %s · %s `%s`%s', d.id, d.decision, d.rule, d.entity_type, d.entity_id,
                           case when d.merge_log_id is not null then format(' · undo handle `%s`', d.merge_log_id) else '' end),
                    E'\n' order by t.ord)
    into v_merges, v_lines
    from unnest(v_ids) with ordinality as t(id, ord)
    join public.crm_steward_decisions d on d.id = t.id;

  select p.id into v_project from public.projects p where p.user_id = v_uid and p.project_key = 'SB';
  select w.id into v_epic from public.work_items w where w.user_id = v_uid and w.ticket_code = 'SB-570';
  if v_project is not null then
    insert into public.work_items (project_id, parent_id, type, title, description, status, priority, assignee, user_id, meta)
    values (v_project, v_epic, 'task',
      format('CRM Steward QA sample: week of %s (%s decisions, %s merges)',
             to_char((now() at time zone 'America/New_York')::date, 'YYYY-MM-DD'), v_n, v_merges),
      format(E'Weekly QA sample of the CRM Data Steward''s automatic decisions (ADR-CRM-006 §7, SB-575). Run %s.\n\n'
             || E'For each decision below, check it against the policy and record a verdict as the owner:\n'
             || E'`select public.crm_steward_record_verdict(''<decision id>'', ''correct''|''wrong'', ''<reason_code>'');`\n'
             || E'A wrong merge rate above 2%% over the last 50 merge verdicts suspends auto-merge automatically. '
             || E'Recording a verdict never undoes anything; undo a wrong merge with `crm_unmerge(<undo handle>, ...)` '
             || E'only after Jason or QA decides to.\n\n%s\n\nIds only: look the records up in the CRM; do not copy names or values into this ticket.',
             v_run, v_lines),
      'todo', 'medium', 'SupaBrain QA', v_uid,
      jsonb_build_object('originating_agent', 'CRM Data Steward', 'generated_by', 'crm_steward_qa_sample',
                         'auto_generated', true, 'issue_type', 'crm_steward_qa_sample', 'run_id', v_run,
                         'decision_ids', to_jsonb(v_ids), 'source_ticket', 'SB-575'))
    returning id, ticket_code into v_wi, v_code;
  end if;

  return jsonb_build_object('sampled', v_n, 'merges', v_merges, 'run_id', v_run,
                            'work_item', v_wi, 'ticket_code', v_code);
end $fn$;
comment on function public.crm_steward_qa_sample(integer) is
  'SB-575 / ADR-CRM-006 §7. Weekly QA sample of automatic steward decisions (merges first); opens a SupaBrain QA ticket with ids only.';
revoke all on function public.crm_steward_qa_sample(integer) from public, anon;
grant execute on function public.crm_steward_qa_sample(integer) to authenticated, service_role;

-- ---------------------------------------------------------------- verdicts and auto-suspend
create or replace function public.crm_steward_record_verdict(p_decision uuid, p_verdict text,
                                                             p_reason text default 'qa_review')
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  v_dec    text;
  v_vid    uuid;
  v_n      int;
  v_wrong  int;
  v_rate   numeric;
  v_susp   boolean := false;
begin
  if v_uid is null then
    raise exception 'recording a verdict needs a signed-in owner' using errcode = '42501';
  end if;
  if p_verdict is null or p_verdict not in ('correct', 'wrong') then
    raise exception 'verdict must be correct or wrong' using errcode = '22023';
  end if;
  select d.decision into v_dec from public.crm_steward_decisions d
   where d.id = p_decision and d.user_id = v_uid;
  if v_dec is null or v_dec not in ('auto_confirm', 'auto_merge', 'auto_resolve', 'auto_expire', 'auto_dismiss') then
    raise exception 'verdicts apply only to the owner''s automatic decisions' using errcode = '22023';
  end if;

  insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, refers_to, qa_verdict)
  values ('qa_verdict', 'qa_review', 'crm_steward_decisions', p_decision, coalesce(p_reason, 'qa_review'), p_decision, p_verdict)
  returning id into v_vid;

  -- latest verdict per merge decision, last 50 such decisions by verdict order
  select count(*), count(*) filter (where l.qa_verdict = 'wrong') into v_n, v_wrong
    from (select x.qa_verdict
            from (select distinct on (v.refers_to) v.refers_to, v.qa_verdict, v.seq
                    from public.crm_steward_decisions v
                    join public.crm_steward_decisions t on t.id = v.refers_to and t.user_id = v_uid
                                                       and t.decision = 'auto_merge'
                   where v.user_id = v_uid and v.decision = 'qa_verdict'
                   order by v.refers_to, v.seq desc) x
           order by x.seq desc
           limit 50) l;
  v_rate := case when v_n > 0 then round(v_wrong::numeric / v_n, 4) end;

  if v_n > 0 and v_wrong::numeric / v_n > 0.02 and not public.crm_steward_suspended() then
    insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, refers_to)
    values ('suspend', 'qa_wrong_merge_rate', 'crm_steward_decisions', v_vid, 'qa_suspend', v_vid);
    v_susp := true;
  end if;

  return jsonb_build_object('verdict_id', v_vid, 'decision', v_dec, 'verdict', p_verdict,
                            'merge_verdicts', v_n, 'wrong_merges', v_wrong, 'wrong_merge_rate', v_rate,
                            'suspended_now', v_susp, 'suspended', public.crm_steward_suspended());
end $fn$;
comment on function public.crm_steward_record_verdict(uuid, text, text) is
  'SB-575 / ADR-CRM-006 §7. Records a QA verdict on an automatic steward decision; suspends auto-merge when the wrong-merge rate over the last 50 merge verdicts exceeds 2%.';
revoke all on function public.crm_steward_record_verdict(uuid, text, text) from public, anon;
grant execute on function public.crm_steward_record_verdict(uuid, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------- scheduled wrapper: add 'weekly'
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
  if p_task is null or p_task not in ('daily', 'weekly') then
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
    else  -- weekly (SB-575; SB-574 adds the digest)
      v_out := jsonb_build_object('qa_sample', public.crm_steward_qa_sample(10));
      v_note := case when (v_out#>>'{qa_sample,skipped}')::boolean then 'qa sample skipped (already taken this week)'
                     else format('qa sample %s (merges %s) %s', v_out#>>'{qa_sample,sampled}',
                                 v_out#>>'{qa_sample,merges}', coalesce(v_out#>>'{qa_sample,ticket_code}', 'no ticket')) end;
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

-- ---------------------------------------------------------------- weekly schedule (Mon 10:40 UTC)
select cron.unschedule(jobid) from cron.job where jobname = 'crm-steward-weekly';
select cron.schedule('crm-steward-weekly', '40 10 * * 1', $job$
do $run$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select a.user_id from public.agents a
                               where a.id = '35c61865-2677-42fd-aad3-d2aa8fa81e85'),
                      'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.crm_steward_scheduled('weekly');
end $run$;
$job$);

-- ---------------------------------------------------------------- assertions
do $chk$
declare f text;
begin
  foreach f in array array['public.crm_steward_qa_sample(integer)', 'public.crm_steward_record_verdict(uuid,text,text)',
                           'public.crm_steward_scheduled(text)'] loop
    if exists (select 1 from pg_proc where oid = f::regprocedure
                and (prosecdef or not proconfig @> array['search_path=""']))
       or has_function_privilege('anon', f, 'execute') then
      raise exception 'A1: % must be SECURITY INVOKER, pinned, and closed to anon', f;
    end if;
  end loop;
  if (select prosrc from pg_proc where oid = 'public.crm_steward_scheduled(text)'::regprocedure) ~ 'duration_ms' then
    raise exception 'A2: crm_steward_scheduled must not write the generated duration_ms';
  end if;
  if not exists (select 1 from cron.job where jobname = 'crm-steward-weekly' and active and schedule = '40 10 * * 1'
                   and command ~ 'set local role authenticated' and command ~ 'crm_steward_scheduled\(''weekly''\)'
                   and command ~ 'a\.id = ''35c61865-2677-42fd-aad3-d2aa8fa81e85''' and command !~ 'a\.name') then
    raise exception 'A3: the weekly job must exist, resolve the owner by agent id, and switch role';
  end if;
  if exists (select 1 from cron.job where command ~* 'crm_steward_run|crm_steward_qa_sample|crm_steward_record_verdict') then
    raise exception 'A4: cron jobs may call only crm_steward_scheduled';
  end if;
end $chk$;
