-- SB-593 (ADR-FLOW-005 D1-D3; SB-550 cancelled as its duplicate).
-- Sweeps could not tell a ticket waiting on an outside party from a neglected one:
-- 39P-026 (waiting on a city agency, follow-up 2026-11-06) counted in
-- vw_audit_health_checks.stale_wip_gt3d and its review dwell grew 24h a day.
--
-- 1. Contract: four work_items meta keys registered in meta_key_registry.
-- 2. One classifier: external_wait_clock(meta, due_date) and
--    work_item_wait_state(meta, due_date, today). A malformed date yields NULL,
--    never an error. Status is ignored.
-- 3. v_external_wait_status (security invoker): every open wait with party,
--    clock, clock source and severity info / escalate / data_quality.
-- 4. Exclusions: stale/overdue/blocked counts skip live waits (expired clocks stay
--    counted); jarvis_ops_metrics appends two counts; both review SLA views and
--    review_sla_sweep() skip every wait. Existing columns keep name, type, order.
-- No ticket data is changed. generate_daily_audit is out of scope (ADR section 5).

-- 1 ---------------------------------------------------------------------------
insert into public.meta_key_registry (table_name, key_name, owner, reason) values
  ('work_items', 'awaiting_external', 'System Architect',
   'SB-593 / ADR-FLOW-005 D1: text naming the outside party that has the next move. Present, non-empty and not ''false'' means waiting. Read by work_item_wait_state.'),
  ('work_items', 'external_ref', 'System Architect',
   'SB-593 / ADR-FLOW-005 D1: optional external reference (e.g. an SR number) for the wait.'),
  ('work_items', 'external_since', 'System Architect',
   'SB-593 / ADR-FLOW-005 D1: YYYY-MM-DD on which our action completed and the wait began.'),
  ('work_items', 'external_clock_expires', 'System Architect',
   'SB-593 / ADR-FLOW-005 D1: YYYY-MM-DD on which the outside party''s window lapses = our follow-up date. Falls back to due_date when absent or malformed.')
on conflict (table_name, key_name) do nothing;

-- 2 ---------------------------------------------------------------------------
create or replace function public.external_wait_clock(p_meta jsonb, p_due date)
returns date
language plpgsql
stable
set search_path = public
as $$
declare
  v_raw text := p_meta->>'external_clock_expires';
  v_clock date;
begin
  if v_raw ~ '^\d{4}-\d{2}-\d{2}$' then
    begin
      v_clock := v_raw::date;
    exception when others then
      v_clock := null;
    end;
  end if;
  return coalesce(v_clock, p_due);
end;
$$;

comment on function public.external_wait_clock(jsonb, date) is
  'SB-593 / ADR-FLOW-005 D2: the follow-up clock of a wait: a valid meta.external_clock_expires, else due_date. A malformed date yields NULL, never an error.';

create or replace function public.work_item_wait_state(p_meta jsonb, p_due date, p_today date default current_date)
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  v_party text := nullif(btrim(p_meta->>'awaiting_external'), '');
  v_clock date;
begin
  if v_party is null or lower(v_party) = 'false' then
    return null;
  end if;
  v_clock := public.external_wait_clock(p_meta, p_due);
  if v_clock is null then
    return 'waiting_no_clock';
  elsif p_today <= v_clock then
    return 'waiting_on_track';
  else
    return 'external_clock_expired';
  end if;
end;
$$;

comment on function public.work_item_wait_state(jsonb, date, date) is
  'SB-593 / ADR-FLOW-005 D2: NULL (not waiting), waiting_on_track, external_clock_expired or waiting_no_clock. Ignores status.';

revoke all on function public.external_wait_clock(jsonb, date) from public;
revoke all on function public.work_item_wait_state(jsonb, date, date) from public;
grant execute on function public.external_wait_clock(jsonb, date) to anon, authenticated, service_role;
grant execute on function public.work_item_wait_state(jsonb, date, date) to anon, authenticated, service_role;

-- 3 ---------------------------------------------------------------------------
create view public.v_external_wait_status with (security_invoker = true) as
select w.id,
       w.user_id,
       w.project_id,
       p.project_key,
       w.ticket_code,
       w.status,
       w.assignee,
       w.priority,
       case when lower(btrim(w.meta->>'awaiting_external')) in ('true', 'yes', 'y', '1') then null
            else btrim(w.meta->>'awaiting_external') end as external_party,
       nullif(btrim(w.meta->>'external_ref'), '') as external_ref,
       public.external_wait_clock(jsonb_build_object('external_clock_expires', w.meta->>'external_since'), null) as external_since,
       c.clock as clock_expires,
       case when public.external_wait_clock(w.meta, null) is not null then 'meta'
            when c.clock is not null then 'due_date'
            else null end as clock_source,
       c.clock - current_date as days_to_clock,
       s.wait_state,
       case s.wait_state when 'waiting_on_track' then 'info'
                         when 'external_clock_expired' then 'escalate'
                         else 'data_quality' end as severity
  from public.work_items w
  left join public.projects p on p.id = w.project_id
  cross join lateral (select public.external_wait_clock(w.meta, w.due_date) as clock) c
  cross join lateral (select public.work_item_wait_state(w.meta, w.due_date) as wait_state) s
 where w.status not in ('done', 'cancelled')
   and w.archived = false
   and s.wait_state is not null;

comment on view public.v_external_wait_status is
  'SB-593 / ADR-FLOW-005 D2: open, non-archived items waiting on an outside party. severity info = on track, escalate = clock lapsed, data_quality = no clock.';

revoke all on public.v_external_wait_status from public, anon;
grant select on public.v_external_wait_status to authenticated, service_role;

-- 4 ---------------------------------------------------------------------------
create or replace view public.vw_audit_health_checks with (security_invoker = true) as
 SELECT ( SELECT count(*) AS count
           FROM work_items w
          WHERE w.status = 'in_progress'::text AND w.updated_at < (now() - '3 days'::interval)
            AND coalesce(public.work_item_wait_state(w.meta, w.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock')) AS stale_wip_gt3d,
    ( SELECT count(*) AS count
           FROM ( SELECT work_items.assignee
                   FROM work_items
                  WHERE work_items.status = 'in_progress'::text AND work_items.assignee IS NOT NULL
                  GROUP BY work_items.assignee
                 HAVING count(*) > 5) s) AS assignees_over_wip,
    ( SELECT count(*) AS count
           FROM work_items
          WHERE work_items.status = 'done'::text AND (work_items.approval_status = ANY (ARRAY['pending'::text, 'rejected'::text])) AND work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone) AS leak_done_unapproved,
    ( SELECT count(*) AS count
           FROM work_items
          WHERE work_items.status = 'done'::text AND (work_items.type <> ALL (ARRAY['epic'::text, 'chore'::text, 'spike'::text, 'requirement'::text])) AND work_items.review_entered_at IS NULL AND work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone) AS leak_done_no_review,
    ( SELECT COALESCE(array_agg(work_items.ticket_code), '{}'::text[]) AS "coalesce"
           FROM work_items
          WHERE work_items.status = 'done'::text AND (work_items.approval_status = ANY (ARRAY['pending'::text, 'rejected'::text])) AND work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone) AS leak_unapproved_tickets,
    ( SELECT COALESCE(array_agg(x.ticket_code), '{}'::text[]) AS "coalesce"
           FROM ( SELECT work_items.ticket_code
                   FROM work_items
                  WHERE work_items.status = 'done'::text AND (work_items.type <> ALL (ARRAY['epic'::text, 'chore'::text, 'spike'::text, 'requirement'::text])) AND work_items.review_entered_at IS NULL AND work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone
                  ORDER BY work_items.updated_at DESC
                 LIMIT 50) x) AS leak_no_review_sample,
    now() AS computed_at;

create or replace view public.jarvis_ops_metrics with (security_invoker = true) as
 WITH agent_perf AS (
         SELECT agent_runs.agent_id,
            count(*) AS total_runs,
            count(*) FILTER (WHERE agent_runs.status = 'failed'::text) AS failed_runs,
            round(avg(agent_runs.duration_ms) FILTER (WHERE agent_runs.status = 'completed'::text), 0) AS avg_duration_ms,
            percentile_cont(0.95::double precision) WITHIN GROUP (ORDER BY (agent_runs.duration_ms::double precision)) FILTER (WHERE agent_runs.status = 'completed'::text) AS p95_duration_ms,
            round(avg(agent_runs.tokens_total) FILTER (WHERE agent_runs.status = 'completed'::text), 0) AS avg_tokens,
            max(agent_runs.started_at) AS last_run
           FROM agent_runs
          GROUP BY agent_runs.agent_id
        ), work_health AS (
         SELECT work_items.user_id,
            count(*) FILTER (WHERE work_items.status <> 'cancelled'::text) AS total_items,
            count(*) FILTER (WHERE work_items.status = 'done'::text) AS done_items,
            count(*) FILTER (WHERE (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text, 'backlog'::text])) AND work_items.updated_at < (now() - '14 days'::interval)
                               AND coalesce(public.work_item_wait_state(work_items.meta, work_items.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock')) AS stale_items,
            count(*) FILTER (WHERE work_items.due_date < CURRENT_DATE AND (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text]))
                               AND coalesce(public.work_item_wait_state(work_items.meta, work_items.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock')) AS overdue_items,
            count(*) FILTER (WHERE (work_items.status = ANY (ARRAY['in_progress'::text, 'review'::text])) AND work_items.updated_at < (now() - '7 days'::interval)
                               AND coalesce(public.work_item_wait_state(work_items.meta, work_items.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock')) AS blocked_items,
            count(*) FILTER (WHERE work_items.assigned_agent_id IS NULL AND (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text, 'backlog'::text]))) AS unassigned_items,
            count(*) FILTER (WHERE work_items.status = 'cancelled'::text) AS cancelled_items,
            count(*) FILTER (WHERE (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text])) AND work_items.archived = false
                               AND public.work_item_wait_state(work_items.meta, work_items.due_date) = 'waiting_on_track') AS external_wait_on_track,
            count(*) FILTER (WHERE (work_items.status <> ALL (ARRAY['done'::text, 'cancelled'::text])) AND work_items.archived = false
                               AND public.work_item_wait_state(work_items.meta, work_items.due_date) = 'external_clock_expired') AS external_clock_expired
           FROM work_items
          GROUP BY work_items.user_id
        ), test_health AS (
         SELECT test_cases.user_id,
            count(*) AS total_cases,
            count(*) FILTER (WHERE test_cases.status = 'passed'::text) AS passed,
            count(*) FILTER (WHERE test_cases.status = 'failed'::text) AS failed,
                CASE
                    WHEN count(*) FILTER (WHERE test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text])) > 0 THEN round(count(*) FILTER (WHERE test_cases.status = 'passed'::text)::numeric / count(*) FILTER (WHERE test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text]))::numeric * 100::numeric, 1)
                    ELSE 0::numeric
                END AS pass_rate
           FROM test_cases
          GROUP BY test_cases.user_id
        ), briefing_health AS (
         SELECT DISTINCT ON (jarvis_briefings.user_id) jarvis_briefings.user_id,
            COALESCE(jsonb_array_length(jarvis_briefings.recommendations), 0) AS open_recommendations,
            COALESCE(jsonb_array_length(jarvis_briefings.flags), 0) AS open_flags,
            jarvis_briefings.briefing_date AS last_briefing_date
           FROM jarvis_briefings
          ORDER BY jarvis_briefings.user_id, jarvis_briefings.briefing_date DESC
        )
 SELECT wh.user_id,
    wh.total_items,
    wh.done_items,
        CASE
            WHEN wh.total_items > 0 THEN round(wh.done_items::numeric / wh.total_items::numeric * 100::numeric, 1)
            ELSE 0::numeric
        END AS completion_pct,
    wh.stale_items,
    wh.overdue_items,
    wh.blocked_items,
    wh.unassigned_items,
    COALESCE(th.pass_rate, 0::numeric) AS test_pass_rate,
    COALESCE(th.total_cases, 0::bigint) AS total_test_cases,
    COALESCE(th.failed, 0::bigint) AS failed_tests,
    COALESCE(bh.open_recommendations, 0) AS open_recommendations,
    COALESCE(bh.open_flags, 0) AS open_flags,
    bh.last_briefing_date,
    ( SELECT count(*) AS count
           FROM agent_runs
          WHERE agent_runs.status = 'failed'::text) AS total_agent_failures,
    ( SELECT round(avg(agent_runs.duration_ms), 0) AS round
           FROM agent_runs
          WHERE agent_runs.status = 'completed'::text) AS avg_agent_duration_ms,
    ( SELECT percentile_cont(0.95::double precision) WITHIN GROUP (ORDER BY (agent_runs.duration_ms::double precision)) AS percentile_cont
           FROM agent_runs
          WHERE agent_runs.status = 'completed'::text) AS p95_agent_duration_ms,
    wh.cancelled_items,
    wh.external_wait_on_track,
    wh.external_clock_expired
   FROM work_health wh
     LEFT JOIN test_health th ON th.user_id = wh.user_id
     LEFT JOIN briefing_health bh ON bh.user_id = wh.user_id;

create or replace view public.v_review_dwell_alerts with (security_invoker = true) as
 SELECT wi.id,
    wi.ticket_code,
    wi.title,
    p.project_key,
    wi.assignee,
    wi.user_id,
    wi.review_entered_at,
    round(EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric, 1) AS hours_in_review,
        CASE
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 72::numeric THEN 'hard_breach'::text
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 48::numeric THEN 'soft_breach'::text
            ELSE 'warning'::text
        END AS breach_level,
        CASE
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 72::numeric THEN 1
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 48::numeric THEN 2
            ELSE 3
        END AS severity_rank
   FROM work_items wi
     JOIN projects p ON p.id = wi.project_id
  WHERE wi.status = 'review'::text AND wi.review_entered_at IS NOT NULL AND (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 24::numeric AND p.archived = false AND p.automation_status <> 'paused'::text
    AND public.work_item_wait_state(wi.meta, wi.due_date) IS NULL
  ORDER BY (
        CASE
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 72::numeric THEN 1
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 48::numeric THEN 2
            ELSE 3
        END), (round(EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric, 1)) DESC;

create or replace view public.v_review_sla_breaches with (security_invoker = true) as
 SELECT wi.id,
    wi.ticket_code,
    wi.title,
    wi.assignee,
    p.project_key,
    wi.user_id,
    wi.review_entered_at,
    round(EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric, 1) AS hours_in_review,
        CASE
            WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 72::numeric THEN 'hard'::text
            ELSE 'soft'::text
        END AS breach_level
   FROM work_items wi
     JOIN projects p ON p.id = wi.project_id
  WHERE wi.status = 'review'::text AND wi.review_entered_at IS NOT NULL AND (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600::numeric) >= 48::numeric AND p.archived = false AND p.automation_status <> 'paused'::text
    AND public.work_item_wait_state(wi.meta, wi.due_date) IS NULL;

-- 5 ---------------------------------------------------------------------------
-- review_sla_sweep(): in-place patch (SB-563 technique). The 72h stamp skips waits;
-- the breach list already reads v_review_sla_breaches. Refuses unless the source
-- still has exactly the one filter line it extends.
do $patch$
declare
  v_def text;
  v_new text;
  v_anchor constant text := 'AND review_sla_breached_at IS NULL';
begin
  v_def := pg_get_functiondef('public.review_sla_sweep()'::regprocedure);
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1
     or strpos(v_def, 'work_item_wait_state') > 0 then
    raise exception 'SB-593 patch: review_sla_sweep is not the expected body';
  end if;
  v_new := replace(v_def, v_anchor, v_anchor || E'\n    AND public.work_item_wait_state(meta, due_date) IS NULL');
  if v_new = v_def then
    raise exception 'SB-593 patch: review_sla_sweep replace was a no-op';
  end if;
  execute v_new;
end
$patch$;

-- 6 ---------------------------------------------------------------------------
do $assert$
declare
  v_n int;
  v_t date := current_date;
  v_row record;
  v_view bigint;
begin
  select count(*) into v_n from public.meta_key_registry
   where table_name = 'work_items' and owner = 'System Architect'
     and key_name in ('awaiting_external', 'external_ref', 'external_since', 'external_clock_expires');
  if v_n <> 4 then raise exception 'SB-593: % of 4 registry rows', v_n; end if;

  if to_regprocedure('public.external_wait_clock(jsonb,date)') is null
     or to_regprocedure('public.work_item_wait_state(jsonb,date,date)') is null then
    raise exception 'SB-593: classifier functions missing';
  end if;

  select count(*) into v_n from pg_class
   where oid = to_regclass('public.v_external_wait_status') and reloptions @> array['security_invoker=true'];
  if v_n <> 1 then raise exception 'SB-593: v_external_wait_status missing or not security invoker'; end if;

  -- truth table (TC-SB593-1 a..g)
  if public.work_item_wait_state('{}'::jsonb, v_t + 3, v_t) is not null then raise exception 'SB-593: truth a'; end if;
  if public.work_item_wait_state('{"awaiting_external":"false"}'::jsonb, v_t + 3, v_t) is not null then raise exception 'SB-593: truth b'; end if;
  if public.work_item_wait_state('{"awaiting_external":"  "}'::jsonb, v_t + 3, v_t) is not null then raise exception 'SB-593: truth c'; end if;
  if public.work_item_wait_state(jsonb_build_object('awaiting_external', 'Agency', 'external_clock_expires', (v_t + 5)::text), null, v_t) <> 'waiting_on_track'
     or public.work_item_wait_state(jsonb_build_object('awaiting_external', 'Agency', 'external_clock_expires', v_t::text), null, v_t) <> 'waiting_on_track'
     or public.external_wait_clock(jsonb_build_object('external_clock_expires', (v_t + 5)::text), v_t + 1) <> v_t + 5 then
    raise exception 'SB-593: truth d';
  end if;
  if public.work_item_wait_state(jsonb_build_object('awaiting_external', 'Agency', 'external_clock_expires', (v_t - 1)::text), v_t + 9, v_t) <> 'external_clock_expired' then
    raise exception 'SB-593: truth e';
  end if;
  if public.work_item_wait_state('{"awaiting_external":"Agency"}'::jsonb, null, v_t) <> 'waiting_no_clock' then raise exception 'SB-593: truth f'; end if;
  if public.external_wait_clock('{"external_clock_expires":"2026-13-45"}'::jsonb, v_t + 3) <> v_t + 3
     or public.external_wait_clock('{"external_clock_expires":"soon"}'::jsonb, v_t + 3) <> v_t + 3
     or public.work_item_wait_state('{"awaiting_external":"Agency","external_clock_expires":"2026-13-45"}'::jsonb, v_t + 3, v_t) <> 'waiting_on_track'
     or public.work_item_wait_state('{"awaiting_external":"true"}'::jsonb, v_t + 3, v_t) <> 'waiting_on_track' then
    raise exception 'SB-593: truth g';
  end if;

  -- 39P-026 classifies through due_date
  select count(*) into v_n from public.v_external_wait_status
   where ticket_code = '39P-026' and wait_state = 'waiting_on_track'
     and clock_expires = date '2026-11-06' and clock_source = 'due_date';
  if v_n <> 1 then raise exception 'SB-593: 39P-026 row count %', v_n; end if;

  -- stale_wip_gt3d equals the recompute with the exclusion
  select stale_wip_gt3d into v_view from public.vw_audit_health_checks;
  select count(*) into v_n from public.work_items w
   where w.status = 'in_progress' and w.updated_at < now() - interval '3 days'
     and coalesce(public.work_item_wait_state(w.meta, w.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock');
  if v_view <> v_n then raise exception 'SB-593: stale_wip_gt3d % vs recompute %', v_view, v_n; end if;

  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'jarvis_ops_metrics'
     and ((column_name = 'external_wait_on_track' and ordinal_position = 19)
       or (column_name = 'external_clock_expired' and ordinal_position = 20)
       or (column_name = 'cancelled_items' and ordinal_position = 18));
  if v_n <> 3 then raise exception 'SB-593: jarvis_ops_metrics columns %', v_n; end if;

  select count(*) into v_n from pg_class
   where relnamespace = 'public'::regnamespace
     and relname in ('vw_audit_health_checks', 'jarvis_ops_metrics', 'v_review_dwell_alerts', 'v_review_sla_breaches')
     and reloptions @> array['security_invoker=true'];
  if v_n <> 4 then raise exception 'SB-593: % of 4 replaced views kept security_invoker', v_n; end if;

  select count(*) into v_n from pg_proc
   where oid = 'public.review_sla_sweep()'::regprocedure and prosecdef
     and strpos(pg_get_functiondef(oid), 'work_item_wait_state(meta, due_date) IS NULL') > 0;
  if v_n <> 1 then raise exception 'SB-593: review_sla_sweep patch not in place'; end if;
end
$assert$;
