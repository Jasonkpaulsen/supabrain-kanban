-- SB-601, SB-602, SB-603, SB-604 (ADR-FLOW-005 amendment 1: D2a, D3a, D12).
--  D2a (SB-603): external_wait_data_quality(); v_external_wait_status appends data_quality_issue,
--       reports clock_source 'due_date_fallback' and a NULL party for a non-text tag. The
--       classifier (work_item_wait_state, external_wait_clock) is unchanged, so no exclusion moves.
--  D3a (SB-601, SB-602): v_open_work_wait_state, the database classification the edge reads
--       instead of re-deriving it. service_role only.
--  D12 (SB-604): review_sla_sweep() and get_review_alerts() pin search_path = '' and
--       schema-qualify every relation. Bodies otherwise unchanged; grants unchanged.

-- ---------------------------------------------------------------- D2a
create or replace function public.external_wait_data_quality(p_meta jsonb, p_due date)
  returns text language sql stable set search_path = public as $$
  -- Meaningful for an item that is waiting (work_item_wait_state not null). First issue wins.
  select case
           when nullif(btrim(p_meta->>'external_clock_expires'), '') is not null
                and public.external_wait_clock(p_meta, null) is null then 'invalid_clock'
           when jsonb_typeof(p_meta->'awaiting_external') in ('object', 'array') then 'non_text_party'
           when public.external_wait_clock(p_meta, p_due) is null then 'no_clock'
         end
$$;
revoke all on function public.external_wait_data_quality(jsonb, date) from public, anon;
grant execute on function public.external_wait_data_quality(jsonb, date) to authenticated, service_role, pg_read_all_data;

create or replace view public.v_external_wait_status with (security_invoker = true) as
select w.id,
       w.user_id,
       w.project_id,
       p.project_key,
       w.ticket_code,
       w.status,
       w.assignee,
       w.priority,
       case
         when jsonb_typeof(w.meta->'awaiting_external') in ('object', 'array') then null::text
         when lower(btrim(w.meta->>'awaiting_external')) = any (array['true', 'yes', 'y', '1']) then null::text
         else btrim(w.meta->>'awaiting_external')
       end as external_party,
       nullif(btrim(w.meta->>'external_ref'), '') as external_ref,
       public.external_wait_clock(jsonb_build_object('external_clock_expires', w.meta->>'external_since'), null::date) as external_since,
       c.clock as clock_expires,
       case
         when public.external_wait_clock(w.meta, null::date) is not null then 'meta'
         when c.clock is not null and q.issue = 'invalid_clock' then 'due_date_fallback'
         when c.clock is not null then 'due_date'
         else null::text
       end as clock_source,
       c.clock - current_date as days_to_clock,
       s.wait_state,
       case
         when s.wait_state = 'external_clock_expired' then 'escalate'
         when q.issue is not null or s.wait_state <> 'waiting_on_track' then 'data_quality'
         else 'info'
       end as severity,
       q.issue as data_quality_issue
  from public.work_items w
  left join public.projects p on p.id = w.project_id
  cross join lateral (select public.external_wait_clock(w.meta, w.due_date) as clock) c
  cross join lateral (select public.work_item_wait_state(w.meta, w.due_date) as wait_state) s
  cross join lateral (select public.external_wait_data_quality(w.meta, w.due_date) as issue) q
 where w.status <> all (array['done', 'cancelled']) and w.archived = false and s.wait_state is not null;

-- ---------------------------------------------------------------- D3a
create or replace view public.v_open_work_wait_state with (security_invoker = true) as
select w.ticket_code,
       w.title,
       w.status,
       w.assignee,
       w.priority,
       w.project_id,
       w.updated_at,
       w.review_entered_at,
       public.work_item_wait_state(w.meta, w.due_date) as wait_state
  from public.work_items w
 where not w.archived and w.status not in ('done', 'cancelled');
revoke all on public.v_open_work_wait_state from public, anon, authenticated;
grant select on public.v_open_work_wait_state to service_role;

-- ---------------------------------------------------------------- D12
create or replace function public.review_sla_sweep()
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
DECLARE
  v_breaches jsonb;
  v_over jsonb;
  v_stamped integer;
  v_summary text;
BEGIN
  -- Auto-stamp review_sla_breached_at on items that hit 72h hard breach
  UPDATE public.work_items
  SET review_sla_breached_at = now(),
      updated_at = now()
  WHERE status = 'review'
    AND review_entered_at IS NOT NULL
    AND review_sla_breached_at IS NULL
    AND public.work_item_wait_state(meta, due_date) IS NULL
    AND EXTRACT(epoch FROM (now() - review_entered_at)) / 3600.0 >= 72;
  GET DIAGNOSTICS v_stamped = ROW_COUNT;

  -- Collect current breaches (48h+)
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'ticket', ticket_code,
    'reviewer', assignee,
    'hours', hours_in_review,
    'level', breach_level
  ) ORDER BY hours_in_review DESC), '[]'::jsonb)
  INTO v_breaches
  FROM public.v_review_sla_breaches;

  -- Collect WIP-overloaded flags
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'ticket', ticket_code,
    'note', meta->>'reviewer_over_wip'
  )), '[]'::jsonb)
  INTO v_over
  FROM public.work_items
  WHERE status = 'review' AND NOT archived AND meta ? 'reviewer_over_wip';

  v_summary := CASE
    WHEN jsonb_array_length(v_breaches) = 0 AND jsonb_array_length(v_over) = 0
      THEN 'Review SLA: all clear — no breach over 48h, no overloaded reviewer.'
    ELSE format('Review SLA: %s breach(es) (48h+), %s newly stamped at 72h, %s overloaded-reviewer flag(s).',
                jsonb_array_length(v_breaches), v_stamped, jsonb_array_length(v_over))
  END;

  INSERT INTO public.activity_log (project_id, user_id, agent_name, action, target_table, summary, meta)
  VALUES (
    'a07a7f3d-722f-468f-81fa-84e2c5fba704',
    '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
    'System',
    'commented',
    'work_items',
    v_summary,
    jsonb_build_object(
      'artifact', 'review_sla',
      'breaches', v_breaches,
      'overloaded', v_over,
      'auto_stamped_count', v_stamped
    )
  );

  RETURN jsonb_build_object(
    'summary', v_summary,
    'breaches', v_breaches,
    'overloaded', v_over,
    'auto_stamped_count', v_stamped
  );
END;
$function$;

create or replace function public.get_review_alerts(min_hours numeric default 24, target_project_key text default null::text)
 returns table(item_id uuid, ticket_code text, title text, project_key text, assignee text, hours_in_review numeric, breach_level text, severity_rank integer)
 language sql
 stable security definer
 set search_path = ''
as $function$
    SELECT
        id AS item_id,
        ticket_code,
        title,
        project_key,
        assignee,
        hours_in_review,
        breach_level,
        severity_rank
    FROM public.v_review_dwell_alerts
    WHERE hours_in_review >= min_hours
      AND (target_project_key IS NULL OR v_review_dwell_alerts.project_key = target_project_key)
    ORDER BY severity_rank ASC, hours_in_review DESC;
$function$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------- assertions
do $assert$
declare n int; t text;
begin
  -- D2a truth table
  if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"2026-11-06T00:00:00Z"}', current_date) is distinct from 'invalid_clock'
     or public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":" 2026-11-06"}', null) is distinct from 'invalid_clock'
     or public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"2026-02-30"}', current_date) is distinct from 'invalid_clock'
     or public.external_wait_data_quality('{"awaiting_external":{"a":1},"external_clock_expires":"2026-11-06"}', null) is distinct from 'non_text_party'
     or public.external_wait_data_quality('{"awaiting_external":"P"}', null) is distinct from 'no_clock'
     or public.external_wait_data_quality('{"awaiting_external":"P"}', current_date) is not null
     or public.external_wait_data_quality('{"awaiting_external":true}', current_date) is not null
     or public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"   "}', current_date) is not null then
    raise exception 'SB-603: external_wait_data_quality truth table';
  end if;
  -- D2a view shape: 17 columns, data_quality_issue last, posture kept
  select count(*), max(attname::text) filter (where attnum = 17) into n, t
    from pg_attribute where attrelid = 'public.v_external_wait_status'::regclass and attnum > 0 and not attisdropped;
  if n <> 17 or t <> 'data_quality_issue'
     or not exists (select 1 from pg_class where oid = 'public.v_external_wait_status'::regclass and reloptions @> array['security_invoker=true'])
     or has_table_privilege('anon', 'public.v_external_wait_status', 'select')
     or not has_table_privilege('authenticated', 'public.v_external_wait_status', 'select') then
    raise exception 'SB-603: v_external_wait_status shape or posture (% columns, last %)', n, t;
  end if;
  -- classification unchanged: the view lists exactly the open waits
  if (select count(*) from public.v_external_wait_status)
     <> (select count(*) from public.work_items w where not w.archived and w.status not in ('done', 'cancelled')
                                                  and public.work_item_wait_state(w.meta, w.due_date) is not null) then
    raise exception 'SB-603: v_external_wait_status no longer lists every open wait';
  end if;
  -- D3a posture and coverage
  if not exists (select 1 from pg_class where oid = 'public.v_open_work_wait_state'::regclass and reloptions @> array['security_invoker=true'])
     or has_table_privilege('anon', 'public.v_open_work_wait_state', 'select')
     or has_table_privilege('authenticated', 'public.v_open_work_wait_state', 'select')
     or not has_table_privilege('service_role', 'public.v_open_work_wait_state', 'select') then
    raise exception 'SB-602: v_open_work_wait_state posture';
  end if;
  if (select count(*) from public.v_open_work_wait_state)
     <> (select count(*) from public.work_items where not archived and status not in ('done', 'cancelled')) then
    raise exception 'SB-602: v_open_work_wait_state does not cover every open item';
  end if;
  -- D12 posture
  select count(*) into n from pg_proc p
   where p.oid in ('public.review_sla_sweep()'::regprocedure, 'public.get_review_alerts(numeric,text)'::regprocedure)
     and p.prosecdef and p.proconfig = array['search_path=""']
     and not has_function_privilege('anon', p.oid, 'execute')
     and not has_function_privilege('authenticated', p.oid, 'execute')
     and has_function_privilege('service_role', p.oid, 'execute');
  if n <> 2 then raise exception 'SB-604: % of 2 functions pinned with grants unchanged', n; end if;
  if strpos(pg_get_functiondef('public.review_sla_sweep()'::regprocedure), 'work_item_wait_state(meta, due_date) IS NULL') = 0 then
    raise exception 'SB-604: review_sla_sweep lost the SB-593 wait-state anchor';
  end if;
end
$assert$;
