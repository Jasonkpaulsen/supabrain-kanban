-- SB-439: repair — five views production has and no migration creates.
--
-- Placed at 20260802002841, immediately before 20260802002842_sb235_views_security_invoker,
-- which ALTERs vw_audit_health_checks. The other four are referenced by no migration
-- at all; they sit here because every table they read must already exist, and by this
-- point in the history they all do (process_audits 20260607234521, trade_signals
-- 20260610022831, jarvis_briefings 20260606192830, test_cases 20260606181816, plus
-- agent_runs from the SB-439 repair at 20260531010318).
--
-- All five carry security_invoker = true, matching production. That is deliberate and
-- not cosmetic: SB-431 found sixteen SECURITY DEFINER views that ignored the caller's
-- RLS and exposed 1,383 work items to anon. Creating them any other way here would
-- reintroduce exactly that defect for the window before the later ALTER runs.
-- The subsequent ALTER on vw_audit_health_checks becomes a no-op, which is fine.

create or replace view public.trade_signals_cleared
with (security_invoker = true) as
 SELECT id,
    market_ticker,
    event_ticker,
    market_title,
    recommended_side,
    market_price_cents,
    model_probability,
    edge,
    kelly_fraction,
    recommended_size_usd,
    rating,
    rating_components,
    confidence_label,
    data_quality,
    liquidity_score,
    close_time,
    sentinel_cleared,
    sentinel_verdict,
    rationale,
    sources,
    status,
    created_at,
    expires_at
   FROM trade_signals
  WHERE ((sentinel_cleared = true) AND (status = 'proposed'::text) AND (archived = false));

create or replace view public.agent_performance_detail
with (security_invoker = true) as
 SELECT ar.agent_id,
    a.name AS agent_name,
    ar.user_id,
    count(*) AS total_runs,
    count(*) FILTER (WHERE (ar.status = 'completed'::text)) AS completed_runs,
    count(*) FILTER (WHERE (ar.status = 'failed'::text)) AS failed_runs,
    count(*) FILTER (WHERE (ar.status = 'timeout'::text)) AS timeout_runs,
        CASE
            WHEN (count(*) > 0) THEN round((((count(*) FILTER (WHERE (ar.status = 'failed'::text)))::numeric / (count(*))::numeric) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS failure_rate_pct,
    round(avg(ar.duration_ms) FILTER (WHERE (ar.status = 'completed'::text)), 0) AS avg_duration_ms,
    percentile_cont((0.50)::double precision) WITHIN GROUP (ORDER BY ((ar.duration_ms)::double precision)) FILTER (WHERE (ar.status = 'completed'::text)) AS p50_duration_ms,
    percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((ar.duration_ms)::double precision)) FILTER (WHERE (ar.status = 'completed'::text)) AS p95_duration_ms,
    percentile_cont((0.99)::double precision) WITHIN GROUP (ORDER BY ((ar.duration_ms)::double precision)) FILTER (WHERE (ar.status = 'completed'::text)) AS p99_duration_ms,
    round(avg(ar.tokens_total) FILTER (WHERE (ar.status = 'completed'::text)), 0) AS avg_tokens,
    sum(ar.tokens_total) AS total_tokens_consumed,
    round(avg(ar.tool_calls) FILTER (WHERE (ar.status = 'completed'::text)), 1) AS avg_tool_calls,
    round(avg(ar.api_calls) FILTER (WHERE (ar.status = 'completed'::text)), 1) AS avg_api_calls,
    sum(ar.items_created) AS total_items_created,
    sum(ar.items_updated) AS total_items_updated,
    max(ar.started_at) AS last_run_at
   FROM (agent_runs ar
     LEFT JOIN agents a ON ((a.id = ar.agent_id)))
  GROUP BY ar.agent_id, a.name, ar.user_id;

create or replace view public.audit_history_timeline
with (security_invoker = true) as
 SELECT pa.id,
    pa.user_id,
    pa.project_id,
    p.name AS project_name,
    pa.audit_date,
    pa.audit_type,
    pa.status AS audit_status,
    pa.auditor_agent_id,
    a.name AS auditor_name,
    ((pa.flow_metrics ->> 'total_items'::text))::integer AS total_items,
    ((pa.flow_metrics ->> 'done_today'::text))::integer AS done_today,
    ((pa.flow_metrics ->> 'created_today'::text))::integer AS created_today,
    ((pa.flow_metrics ->> 'stale_14d'::text))::integer AS stale_items,
    ((pa.flow_metrics ->> 'blocked'::text))::integer AS blocked_items,
    ((pa.flow_metrics ->> 'overdue'::text))::integer AS overdue_items,
    ((pa.flow_metrics ->> 'avg_age_days'::text))::numeric AS avg_age_days,
    ((pa.governance_violations ->> 'missing_description'::text))::integer AS missing_description,
    ((pa.governance_violations ->> 'missing_priority'::text))::integer AS missing_priority,
    ((pa.governance_violations ->> 'unapproved_past_gate'::text))::integer AS unapproved_past_gate,
    ((pa.qa_coverage_stats ->> 'total_cases'::text))::integer AS total_test_cases,
    ((pa.qa_coverage_stats ->> 'pass_rate'::text))::numeric AS test_pass_rate,
    pa.recommendations_count,
    pa.flags_count,
    pa.violations_count,
    pa.max_severity,
    pa.created_at
   FROM ((process_audits pa
     LEFT JOIN projects p ON ((p.id = pa.project_id)))
     LEFT JOIN agents a ON ((a.id = pa.auditor_agent_id)))
  ORDER BY pa.audit_date DESC;

create or replace view public.vw_audit_health_checks
with (security_invoker = true) as
 SELECT ( SELECT count(*) AS count
           FROM work_items
          WHERE ((work_items.status = 'in_progress'::text) AND (work_items.updated_at < (now() - '3 days'::interval)))) AS stale_wip_gt3d,
    ( SELECT count(*) AS count
           FROM ( SELECT work_items.assignee
                   FROM work_items
                  WHERE ((work_items.status = 'in_progress'::text) AND (work_items.assignee IS NOT NULL))
                  GROUP BY work_items.assignee
                 HAVING (count(*) > 5)) s) AS assignees_over_wip,
    ( SELECT count(*) AS count
           FROM work_items
          WHERE ((work_items.status = 'done'::text) AND (work_items.approval_status = ANY (ARRAY['pending'::text, 'rejected'::text])) AND (work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone))) AS leak_done_unapproved,
    ( SELECT count(*) AS count
           FROM work_items
          WHERE ((work_items.status = 'done'::text) AND (work_items.type <> ALL (ARRAY['epic'::text, 'chore'::text, 'spike'::text, 'requirement'::text])) AND (work_items.review_entered_at IS NULL) AND (work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone))) AS leak_done_no_review,
    ( SELECT COALESCE(array_agg(work_items.ticket_code), '{}'::text[]) AS "coalesce"
           FROM work_items
          WHERE ((work_items.status = 'done'::text) AND (work_items.approval_status = ANY (ARRAY['pending'::text, 'rejected'::text])) AND (work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone))) AS leak_unapproved_tickets,
    ( SELECT COALESCE(array_agg(x.ticket_code), '{}'::text[]) AS "coalesce"
           FROM ( SELECT work_items.ticket_code
                   FROM work_items
                  WHERE ((work_items.status = 'done'::text) AND (work_items.type <> ALL (ARRAY['epic'::text, 'chore'::text, 'spike'::text, 'requirement'::text])) AND (work_items.review_entered_at IS NULL) AND (work_items.created_at >= '2026-06-17 00:00:00+00'::timestamp with time zone))
                  ORDER BY work_items.updated_at DESC
                 LIMIT 50) x) AS leak_no_review_sample,
    now() AS computed_at;

create or replace view public.jarvis_ops_metrics
with (security_invoker = true) as
 WITH agent_perf AS (
         SELECT agent_runs.agent_id,
            count(*) AS total_runs,
            count(*) FILTER (WHERE (agent_runs.status = 'failed'::text)) AS failed_runs,
            round(avg(agent_runs.duration_ms) FILTER (WHERE (agent_runs.status = 'completed'::text)), 0) AS avg_duration_ms,
            percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((agent_runs.duration_ms)::double precision)) FILTER (WHERE (agent_runs.status = 'completed'::text)) AS p95_duration_ms,
            round(avg(agent_runs.tokens_total) FILTER (WHERE (agent_runs.status = 'completed'::text)), 0) AS avg_tokens,
            max(agent_runs.started_at) AS last_run
           FROM agent_runs
          GROUP BY agent_runs.agent_id
        ), work_health AS (
         SELECT work_items.user_id,
            count(*) AS total_items,
            count(*) FILTER (WHERE (work_items.status = 'done'::text)) AS done_items,
            count(*) FILTER (WHERE ((work_items.status <> ALL (ARRAY['done'::text, 'backlog'::text])) AND (work_items.updated_at < (now() - '14 days'::interval)))) AS stale_items,
            count(*) FILTER (WHERE ((work_items.due_date < CURRENT_DATE) AND (work_items.status <> 'done'::text))) AS overdue_items,
            count(*) FILTER (WHERE ((work_items.status = ANY (ARRAY['in_progress'::text, 'review'::text])) AND (work_items.updated_at < (now() - '7 days'::interval)))) AS blocked_items,
            count(*) FILTER (WHERE ((work_items.assigned_agent_id IS NULL) AND (work_items.status <> ALL (ARRAY['done'::text, 'backlog'::text])))) AS unassigned_items
           FROM work_items
          GROUP BY work_items.user_id
        ), test_health AS (
         SELECT test_cases.user_id,
            count(*) AS total_cases,
            count(*) FILTER (WHERE (test_cases.status = 'passed'::text)) AS passed,
            count(*) FILTER (WHERE (test_cases.status = 'failed'::text)) AS failed,
                CASE
                    WHEN (count(*) FILTER (WHERE (test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text]))) > 0) THEN round((((count(*) FILTER (WHERE (test_cases.status = 'passed'::text)))::numeric / (count(*) FILTER (WHERE (test_cases.status = ANY (ARRAY['passed'::text, 'failed'::text]))))::numeric) * (100)::numeric), 1)
                    ELSE (0)::numeric
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
            WHEN (wh.total_items > 0) THEN round((((wh.done_items)::numeric / (wh.total_items)::numeric) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS completion_pct,
    wh.stale_items,
    wh.overdue_items,
    wh.blocked_items,
    wh.unassigned_items,
    COALESCE(th.pass_rate, (0)::numeric) AS test_pass_rate,
    COALESCE(th.total_cases, (0)::bigint) AS total_test_cases,
    COALESCE(th.failed, (0)::bigint) AS failed_tests,
    COALESCE(bh.open_recommendations, 0) AS open_recommendations,
    COALESCE(bh.open_flags, 0) AS open_flags,
    bh.last_briefing_date,
    ( SELECT count(*) AS count
           FROM agent_runs
          WHERE (agent_runs.status = 'failed'::text)) AS total_agent_failures,
    ( SELECT round(avg(agent_runs.duration_ms), 0) AS round
           FROM agent_runs
          WHERE (agent_runs.status = 'completed'::text)) AS avg_agent_duration_ms,
    ( SELECT percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((agent_runs.duration_ms)::double precision)) AS percentile_cont
           FROM agent_runs
          WHERE (agent_runs.status = 'completed'::text)) AS p95_agent_duration_ms
   FROM ((work_health wh
     LEFT JOIN test_health th ON ((th.user_id = wh.user_id)))
     LEFT JOIN briefing_health bh ON ((bh.user_id = wh.user_id)));
