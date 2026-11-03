-- SB-574 (ADR-CRM-006 §8): Jason's weekly exception digest, plus immediate escalation of a failed run.
--
-- * crm_steward_digest(p_deliver default false): what the policy leaves to a person, one item per
--   entity (target under 5), ids and counts only:
--     tier_a_conflict, gray_zone_shared_context, restricted_blocks_merge, strong_pair_not_merged,
--     auto_merge_suspended, wrong_merge_not_undone, steward_health;
--   plus, for information only, the last 7 days' automatic merges with their undo handles.
--   "Sensitivity classification" yields no items: classification is always a human act
--   (ADR-CRM-001 §5) and the steward never classifies. p_deliver = false is a read-only preview.
--   p_deliver = true opens one SB ticket: awaiting_jason for JARVIS when there are action items,
--   todo for JARVIS (briefing) when there are only FYI merges, nothing when there is nothing; at
--   most one digest per 6 days.
-- * crm_steward_scheduled: 'weekly' now runs the QA sample and then the digest; a failed scheduled
--   run opens one escalated SB ticket for JARVIS (high), unless an open one already exists. The
--   escalation can never break the run log.
-- All SECURITY INVOKER (owner, RLS), search_path pinned, closed to anon.

create or replace function public.crm_steward_digest(p_deliver boolean default false)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid       uuid := auth.uid();
  v_items     jsonb := '[]'::jsonb;
  v_fyi       jsonb;
  v_n         int;
  v_fyi_n     int;
  v_agent     uuid;
  cand        record;
  pa          public.crm_people%rowtype;
  pb          public.crm_people%rowtype;
  v_restr     boolean;
  v_ctx       text;
  names_ok    boolean;
  by_email    boolean;
  by_phone    boolean;
  v_covered   boolean;
  v_susp      record;
  v_failed    int;
  v_failed_ids jsonb;
  v_streak    boolean;
  v_project   uuid;
  v_epic      uuid;
  v_wi        uuid;
  v_code      text;
  v_status    text;
  v_lines     text;
  v_fyi_lines text;
begin
  if v_uid is null then
    raise exception 'the digest needs a signed-in owner' using errcode = '42501';
  end if;
  if coalesce(p_deliver, false) and exists (
       select 1 from public.work_items w
        where w.user_id = v_uid and w.meta->>'issue_type' = 'crm_steward_digest'
          and w.created_at > now() - interval '6 days') then
    return jsonb_build_object('skipped', true, 'reason', 'a digest was already delivered this week');
  end if;

  -- 1. Tier A against Tier A import conflicts (same tier logic as crm_steward_run, §5)
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object('type', 'tier_a_conflict', 'conflict_id', c.id, 'person_id', c.person_id,
                                        'field', case when c.field like 'role_title@%' then 'role_title' else c.field end)
                     order by c.created_at, c.id)
      from public.crm_import_conflicts c
      join public.crm_import_batches b on b.id = c.batch_id and b.user_id = c.user_id
     where c.user_id = v_uid and c.status = 'open' and not c.archived
       and public.crm_source_tier('import', b.source || coalesce(':' || b.source_label, '')) = 'A'
       and (case
              when c.field in ('given_name', 'middle_name', 'family_name', 'preferred_name', 'display_name') then
                (select public.crm_source_tier(p.source_type, p.source_ref) from public.crm_people p
                  where p.id = c.person_id and p.user_id = v_uid)
              when c.field = 'birthday' then
                (select public.crm_source_tier(d.source_type, d.source_ref) from public.crm_important_dates d
                  where d.user_id = v_uid and d.person_id = c.person_id and d.kind = 'birthday' and not d.archived
                  order by d.created_at limit 1)
              when c.field like 'role_title@%' then
                (select public.crm_source_tier(a.source_type, a.source_ref) from public.crm_affiliations a
                  where a.user_id = v_uid and a.person_id = c.person_id
                    and a.organization_id = substr(c.field, 12)::uuid and not a.archived
                  order by a.created_at limit 1)
            end) = 'A'), '[]'::jsonb);

  -- 2-4. duplicate pairs the policy leaves to a person
  for cand in select * from public.crm_duplicate_candidates(1000) loop
    if cand.strength = 'possible' then
      v_ctx := case
        when exists (select 1 from unnest(cand.reasons) x where x like 'both at %') then 'organization'
        when exists (select 1 from public.crm_group_members g1
                       join public.crm_group_members g2 on g2.group_id = g1.group_id
                                                       and g2.person_id = cand.person_b and not g2.archived
                      where g1.person_id = cand.person_a and not g1.archived) then 'group'
        when exists (select 1 from public.crm_person_relationships x
                      where not x.archived
                        and ((x.person_id = cand.person_a and x.related_person_id = cand.person_b)
                          or (x.person_id = cand.person_b and x.related_person_id = cand.person_a))) then 'relationship'
      end;
      if v_ctx is not null then
        v_items := v_items || jsonb_build_object('type', 'gray_zone_shared_context',
                                                 'person_a', cand.person_a, 'person_b', cand.person_b, 'shares', v_ctx);
      end if;
      continue;
    end if;

    -- strong pair
    v_restr := exists (select 1 from public.crm_facts f where f.person_id in (cand.person_a, cand.person_b)
                         and f.sensitivity in ('sensitive', 'highly_sensitive') and not f.archived)
            or exists (select 1 from public.crm_actions x where x.person_id in (cand.person_a, cand.person_b)
                         and x.sensitivity in ('sensitive', 'highly_sensitive') and not x.archived)
            or exists (select 1 from public.crm_interaction_participants ip
                         join public.crm_interactions i on i.id = ip.interaction_id
                        where ip.person_id in (cand.person_a, cand.person_b) and not i.archived
                          and i.sensitivity in ('sensitive', 'highly_sensitive'));
    if v_restr then
      v_items := v_items || jsonb_build_object('type', 'restricted_blocks_merge',
                                               'person_a', cand.person_a, 'person_b', cand.person_b);
      continue;
    end if;

    -- would the §4 rule (as amended by SB-583) merge it? then the steward does it; not for Jason
    select * into pa from public.crm_people where id = cand.person_a and user_id = v_uid and not archived;
    select * into pb from public.crm_people where id = cand.person_b and user_id = v_uid and not archived;
    continue when pa.id is null or pb.id is null;
    names_ok := (pa.family_name is not null and pb.family_name is not null
                 and lower(btrim(pa.family_name)) = lower(btrim(pb.family_name)))
                or strpos(pa.name_normalized, pb.name_normalized) > 0
                or strpos(pb.name_normalized, pa.name_normalized) > 0;
    by_email := exists (select 1 from unnest(cand.reasons) x where x like 'same email %');
    by_phone := exists (select 1 from unnest(cand.reasons) x where x like 'same phone %')
                and public.crm_given_names_compatible(
                      public.crm_name_tokens(pa.given_name, pa.preferred_name, pa.display_name),
                      public.crm_name_tokens(pb.given_name, pb.preferred_name, pb.display_name));
    v_covered := (names_ok and (by_email or by_phone))
                 or (pa.name_normalized = pb.name_normalized
                     and exists (select 1 from public.crm_affiliations a1
                                   join public.crm_affiliations a2 on a2.organization_id = a1.organization_id
                                                                  and a2.person_id = pb.id and not a2.archived
                                  where a1.person_id = pa.id and not a1.archived));
    if not v_covered then
      v_items := v_items || jsonb_build_object('type', 'strong_pair_not_merged',
        'person_a', cand.person_a, 'person_b', cand.person_b,
        'evidence', (select coalesce(jsonb_agg(distinct case when x like 'same email %' then 'same email'
                                                             when x like 'same phone %' then 'same phone'
                                                             when x like 'both at %' then 'same organization'
                                                             else 'other' end), '[]'::jsonb)
                       from unnest(cand.reasons) x));
    end if;
  end loop;

  -- 5. suspension of auto-merge
  if public.crm_steward_suspended() then
    select d.id, d.refers_to, d.created_at into v_susp
      from public.crm_steward_decisions d
     where d.user_id = v_uid and d.decision = 'suspend' order by d.seq desc limit 1;
    v_items := v_items || jsonb_build_object('type', 'auto_merge_suspended', 'suspend_id', v_susp.id,
                                             'tripped_by_verdict', v_susp.refers_to, 'since', v_susp.created_at);
  end if;

  -- 6. merges QA judged wrong that are still in place
  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object('type', 'wrong_merge_not_undone', 'decision_id', t.id,
                                        'merge_log_id', t.merge_log_id, 'verdict_id', l.id) order by l.seq)
      from (select distinct on (v.refers_to) v.id, v.refers_to, v.qa_verdict, v.seq
              from public.crm_steward_decisions v
             where v.user_id = v_uid and v.decision = 'qa_verdict'
             order by v.refers_to, v.seq desc) l
      join public.crm_steward_decisions t on t.id = l.refers_to and t.user_id = v_uid and t.decision = 'auto_merge'
     where l.qa_verdict = 'wrong'
       and not exists (select 1 from public.crm_unmerges u where u.user_id = v_uid and u.merge_log_id = t.merge_log_id)),
    '[]'::jsonb);

  -- 7. steward health: failed scheduled runs this week; daily runs capped on 3 consecutive days
  select a.id into v_agent from public.agents a
   where a.user_id = v_uid and a.name = 'CRM Data Steward' order by a.created_at limit 1;
  select count(*), coalesce(jsonb_agg(r.id order by r.started_at), '[]'::jsonb) into v_failed, v_failed_ids
    from public.agent_runs r
   where r.user_id = v_uid and r.agent_id = v_agent and r.status = 'failed' and r.started_at > now() - interval '7 days';
  v_streak := (select count(distinct (r.started_at at time zone 'UTC')::date)
                 from public.agent_runs r
                where r.user_id = v_uid and r.agent_id = v_agent and r.status = 'completed'
                  and r.run_metadata->>'task' = 'daily'
                  and coalesce((r.run_metadata#>>'{summary,capped}')::boolean, false)
                  and r.started_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days') = 3;
  if v_failed > 0 or v_streak then
    v_items := v_items || jsonb_build_object('type', 'steward_health', 'failed_runs', v_failed,
                                             'failed_run_ids', v_failed_ids, 'capped_3_days', v_streak);
  end if;

  -- FYI: this week's automatic merges and their undo handles
  select coalesce(jsonb_agg(jsonb_build_object('decision_id', d.id, 'rule', d.rule, 'merge_log_id', d.merge_log_id,
                                               'undone', exists (select 1 from public.crm_unmerges u
                                                                  where u.user_id = v_uid and u.merge_log_id = d.merge_log_id))
                            order by d.seq), '[]'::jsonb)
    into v_fyi
    from public.crm_steward_decisions d
   where d.user_id = v_uid and d.decision = 'auto_merge' and d.created_at > now() - interval '7 days';

  v_n := jsonb_array_length(v_items);
  v_fyi_n := jsonb_array_length(v_fyi);

  if coalesce(p_deliver, false) and (v_n > 0 or v_fyi_n > 0) then
    select p.id into v_project from public.projects p where p.user_id = v_uid and p.project_key = 'SB';
    select w.id into v_epic from public.work_items w where w.user_id = v_uid and w.ticket_code = 'SB-570';
    v_status := case when v_n > 0 then 'awaiting_jason' else 'todo' end;
    select string_agg(format('- **%s** %s', e->>'type', (e - 'type')::text), E'\n' order by o)
      into v_lines from jsonb_array_elements(v_items) with ordinality as t(e, o) where o <= 50;
    select string_agg(format('- `%s` · %s · undo handle `%s`%s', e->>'decision_id', e->>'rule', e->>'merge_log_id',
                             case when (e->>'undone')::boolean then ' · already undone' else '' end), E'\n' order by o)
      into v_fyi_lines from jsonb_array_elements(v_fyi) with ordinality as t(e, o) where o <= 50;
    if v_project is not null then
      insert into public.work_items (project_id, parent_id, type, title, description, status, priority, assignee, user_id, meta)
      values (v_project, v_epic, 'task',
        format('CRM Steward weekly digest: %s item%s for Jason (%s FYI merge%s)',
               v_n, case when v_n = 1 then '' else 's' end, v_fyi_n, case when v_fyi_n = 1 then '' else 's' end),
        format(E'Weekly exception digest of the CRM Data Steward (ADR-CRM-006 §8, SB-574). Target: under 5 items.\n\n'
               || E'**Needs Jason (%s)**\n%s\n\n**For information only: automatic merges in the last 7 days (%s)**\n%s\n\n'
               || E'Ids only. Ask JARVIS to open this digest to see the people behind the ids. '
               || E'Undo a merge with `crm_unmerge(<undo handle>, <reason>)`; resume auto-merge with a `resume` decision.',
               v_n, coalesce(v_lines, '- none') || case when v_n > 50 then format(E'\n- … and %s more', v_n - 50) else '' end,
               v_fyi_n, coalesce(v_fyi_lines, '- none') || case when v_fyi_n > 50 then format(E'\n- … and %s more', v_fyi_n - 50) else '' end),
        v_status, case when v_n > 0 then 'medium' else 'low' end, 'JARVIS — Master Orchestrator', v_uid,
        jsonb_build_object('originating_agent', 'CRM Data Steward', 'generated_by', 'crm_steward_digest',
                           'auto_generated', true, 'issue_type', 'crm_steward_digest', 'flagged_for_jason', v_n > 0,
                           'item_count', v_n, 'fyi_merges', v_fyi_n, 'over_target', v_n >= 5,
                           'item_types', (select jsonb_object_agg(k, c) from (select e->>'type' k, count(*) c
                                            from jsonb_array_elements(v_items) e group by 1) s),
                           'source_ticket', 'SB-574'))
      returning id, ticket_code into v_wi, v_code;
    end if;
  end if;

  return jsonb_build_object('item_count', v_n, 'over_target', v_n >= 5, 'items', v_items,
                            'fyi_merge_count', v_fyi_n, 'fyi_merges', v_fyi,
                            'delivered', v_wi is not null, 'work_item', v_wi, 'ticket_code', v_code, 'status', v_status);
end $fn$;
comment on function public.crm_steward_digest(boolean) is
  'SB-574 / ADR-CRM-006 §8. Jason''s weekly exception digest (ids only) plus FYI automatic merges with undo handles; p_deliver opens one ticket a week.';
revoke all on function public.crm_steward_digest(boolean) from public, anon;
grant execute on function public.crm_steward_digest(boolean) to authenticated, service_role;

-- ---------------------------------------------------------------- scheduled wrapper: digest + failure escalation
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
  v_run_id uuid;
  v_esc    text;
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
    else  -- weekly: QA sample (SB-575), then Jason's digest (SB-574)
      v_out := jsonb_build_object('qa_sample', public.crm_steward_qa_sample(10));
      v_out := v_out || jsonb_build_object('digest', public.crm_steward_digest(true) - 'items' - 'fyi_merges');
      v_note := format('%s; %s',
        case when (v_out#>>'{qa_sample,skipped}')::boolean then 'qa sample skipped (already taken this week)'
             else format('qa sample %s (merges %s) %s', v_out#>>'{qa_sample,sampled}',
                         v_out#>>'{qa_sample,merges}', coalesce(v_out#>>'{qa_sample,ticket_code}', 'no ticket')) end,
        case when (v_out#>>'{digest,skipped}')::boolean then 'digest skipped (already delivered this week)'
             else format('digest %s items, %s FYI merges, %s', v_out#>>'{digest,item_count}',
                         v_out#>>'{digest,fyi_merge_count}', coalesce(v_out#>>'{digest,ticket_code}', 'nothing to send')) end);
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
          jsonb_build_object('task', p_task, 'summary', v_out, 'source', 'crm_steward_scheduled'))
  returning id into v_run_id;

  update public.agents
     set last_run_at = now(),
         run_count   = coalesce(run_count, 0) + 1,
         error_count = coalesce(error_count, 0) + (v_state = 'failed')::int,
         last_error  = case when v_state = 'failed' then v_err else last_error end
   where id = v_agent.id and user_id = v_uid;

  -- SB-574: a failed run escalates at once (one open escalation at a time; never breaks the log)
  if v_state = 'failed' then
    begin
      if not exists (select 1 from public.work_items w
                      where w.user_id = v_uid and w.meta->>'issue_type' = 'crm_steward_run_failed'
                        and w.status <> 'done' and not w.archived) then
        insert into public.work_items (project_id, parent_id, type, title, description, status, priority, assignee, user_id, meta)
        select p.id, (select w.id from public.work_items w where w.user_id = v_uid and w.ticket_code = 'SB-570'), 'bug',
               format('CRM Data Steward: scheduled %s run failed (%s)', p_task, split_part(v_err, ':', 1)),
               format(E'The scheduled CRM Data Steward %s run failed (agent_runs %s, error code %s). '
                      || E'Its work was rolled back, so nothing changed; the next scheduled run retries.\n\n'
                      || E'Look at agent_runs.error_message and cron.job_run_details. While this ticket is open, '
                      || E'further failures are counted in the weekly digest instead of opening new tickets. Ids only.',
                      p_task, v_run_id, split_part(v_err, ':', 1)),
               'escalated', 'high', 'JARVIS — Master Orchestrator', v_uid,
               jsonb_build_object('originating_agent', 'CRM Data Steward', 'generated_by', 'crm_steward_scheduled',
                                  'auto_generated', true, 'issue_type', 'crm_steward_run_failed', 'run_id', v_run_id,
                                  'task', p_task, 'error_code', split_part(v_err, ':', 1), 'source_ticket', 'SB-574')
          from public.projects p where p.user_id = v_uid and p.project_key = 'SB'
        returning ticket_code into v_esc;
      end if;
    exception when others then
      v_esc := null;
    end;
  end if;

  return jsonb_build_object('task', p_task, 'status', v_state, 'summary', v_out, 'error', v_err,
                            'run_id', v_run_id, 'escalation', v_esc);
end $fn$;

-- ---------------------------------------------------------------- assertions
do $chk$
declare f text;
begin
  foreach f in array array['public.crm_steward_digest(boolean)', 'public.crm_steward_scheduled(text)'] loop
    if exists (select 1 from pg_proc where oid = f::regprocedure
                and (prosecdef or not proconfig @> array['search_path=""']))
       or has_function_privilege('anon', f, 'execute') then
      raise exception 'A1: % must be SECURITY INVOKER, pinned, and closed to anon', f;
    end if;
  end loop;
  if (select prosrc from pg_proc where oid = 'public.crm_steward_scheduled(text)'::regprocedure) ~ 'duration_ms' then
    raise exception 'A2: crm_steward_scheduled must not write the generated duration_ms';
  end if;
  if exists (select 1 from cron.job where command ~* 'crm_steward_run|crm_steward_qa_sample|crm_steward_record_verdict|crm_steward_digest') then
    raise exception 'A3: cron jobs may call only crm_steward_scheduled';
  end if;
end $chk$;
