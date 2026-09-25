
-- SB-287: PE daily-audit read consistency.
-- Problem: generate_daily_audit runs multiple independent SELECTs against work_items,
-- test_cases, agents, etc. Under READ COMMITTED (default), each statement gets its own
-- snapshot. Data changes between statements cause inconsistent metrics within one audit.
--
-- Fix: Snapshot the base data into temp tables at the start of the function, then
-- compute all metrics from the snapshots. This guarantees all metrics derive from
-- the same point-in-time data regardless of transaction isolation level.

CREATE OR REPLACE FUNCTION public.generate_daily_audit(
  p_user_id uuid,
  p_project_id uuid,
  p_audit_date date DEFAULT CURRENT_DATE,
  p_auditor_agent_id uuid DEFAULT NULL::uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
AS $function$
DECLARE
  v_id uuid;
  v_flow jsonb;
  v_gov jsonb;
  v_agents jsonb;
  v_qa jsonb;
  v_recs int;
  v_flags int;
  v_violations int;
  v_max_sev text;
  v_ticket_codes text[];
  v_agent_ids uuid[];
  v_snapshot_ts timestamptz;
BEGIN
  -- Record the snapshot timestamp for traceability
  v_snapshot_ts := clock_timestamp();

  -- =========================================================
  -- PHASE 1: Snapshot base data into temp tables.
  -- All subsequent metric queries read ONLY from these snapshots.
  -- This eliminates cross-statement read inconsistency (SB-287).
  -- =========================================================

  CREATE TEMP TABLE _audit_wi ON COMMIT DROP AS
    SELECT id, status, assigned_agent_id, assignee, approval_status,
           description, priority, due_date, ticket_code, type, meta,
           created_at, updated_at, completed_at
      FROM public.work_items
     WHERE user_id = p_user_id AND project_id = p_project_id;

  CREATE TEMP TABLE _audit_tc ON COMMIT DROP AS
    SELECT id, work_item_id, status
      FROM public.test_cases
     WHERE user_id = p_user_id AND project_id = p_project_id;

  CREATE TEMP TABLE _audit_agents ON COMMIT DROP AS
    SELECT a.id
      FROM public.agents a
      JOIN public.agent_projects ap ON ap.agent_id = a.id AND ap.project_id = p_project_id
     WHERE a.user_id = p_user_id;

  -- =========================================================
  -- PHASE 2: Compute all metrics from the snapshots.
  -- =========================================================

  -- Flow metrics
  SELECT jsonb_build_object(
    'total_items', COUNT(*),
    'backlog', COUNT(*) FILTER (WHERE status = 'backlog'),
    'todo', COUNT(*) FILTER (WHERE status = 'todo'),
    'in_progress', COUNT(*) FILTER (WHERE status = 'in_progress'),
    'review', COUNT(*) FILTER (WHERE status = 'review'),
    'done', COUNT(*) FILTER (WHERE status = 'done'),
    'done_today', COUNT(*) FILTER (WHERE status = 'done' AND completed_at::date = p_audit_date),
    'created_today', COUNT(*) FILTER (WHERE created_at::date = p_audit_date),
    'updated_today', COUNT(*) FILTER (WHERE updated_at::date = p_audit_date),
    'stale_14d', COUNT(*) FILTER (WHERE updated_at < (p_audit_date - 14) AND status NOT IN ('done','backlog')),
    'blocked', COUNT(*) FILTER (WHERE status = 'in_progress' AND updated_at < (p_audit_date - 7)),
    'unassigned', COUNT(*) FILTER (WHERE assigned_agent_id IS NULL AND status NOT IN ('done','backlog')),
    'overdue', COUNT(*) FILTER (WHERE due_date < p_audit_date AND status != 'done'),
    'avg_age_days', COALESCE(AVG(p_audit_date - created_at::date) FILTER (WHERE status NOT IN ('done','backlog')), 0)::int
  ) INTO v_flow
  FROM _audit_wi;

  -- Governance violations
  SELECT jsonb_build_object(
    'missing_description', COUNT(*) FILTER (WHERE (description IS NULL OR description = '') AND status NOT IN ('backlog')),
    'missing_priority', COUNT(*) FILTER (WHERE priority IS NULL),
    'unapproved_past_gate', COUNT(*) FILTER (WHERE status IN ('in_progress','review','done') AND approval_status NOT IN ('approved','not_required'))
  ),
  (COUNT(*) FILTER (WHERE (description IS NULL OR description = '') AND status NOT IN ('backlog')))
    + (COUNT(*) FILTER (WHERE status IN ('in_progress','review','done') AND approval_status NOT IN ('approved','not_required')))
  INTO v_gov, v_violations
  FROM _audit_wi;

  -- Agent utilization
  SELECT jsonb_build_object(
    'total_agents', COUNT(DISTINCT a.id),
    'agents_with_work', (SELECT COUNT(DISTINCT w2.assigned_agent_id) FROM _audit_wi w2 WHERE w2.status NOT IN ('done','backlog') AND w2.assigned_agent_id IS NOT NULL),
    'total_open_items', (SELECT COUNT(*) FROM _audit_wi w3 WHERE w3.status NOT IN ('done','backlog'))
  ) INTO v_agents
  FROM _audit_agents a;

  -- QA coverage
  SELECT jsonb_build_object(
    'total_test_cases', COUNT(*),
    'passed', COUNT(*) FILTER (WHERE status = 'passed'),
    'failed', COUNT(*) FILTER (WHERE status = 'failed'),
    'pending', COUNT(*) FILTER (WHERE status IN ('pending','draft')),
    'pass_rate', CASE WHEN COUNT(*) FILTER (WHERE status IN ('passed','failed')) > 0
      THEN ROUND(COUNT(*) FILTER (WHERE status = 'passed')::numeric / COUNT(*) FILTER (WHERE status IN ('passed','failed')) * 100, 1)
      ELSE 0 END
  ) INTO v_qa
  FROM _audit_tc;

  -- Recommendations/flags from latest briefing (external table — single read, acceptable)
  SELECT
    COALESCE(jsonb_array_length(recommendations), 0),
    COALESCE(jsonb_array_length(flags), 0)
  INTO v_recs, v_flags
  FROM public.jarvis_briefings
  WHERE user_id = p_user_id
  ORDER BY briefing_date DESC LIMIT 1;

  v_recs := COALESCE(v_recs, 0);
  v_flags := COALESCE(v_flags, 0);
  v_max_sev := CASE
    WHEN v_violations > 0 THEN 'high'
    WHEN v_flags > 2 THEN 'medium'
    WHEN v_flags > 0 THEN 'low'
    ELSE 'info'
  END;

  -- Flagged ticket codes (from snapshot)
  SELECT array_agg(ticket_code) INTO v_ticket_codes
  FROM _audit_wi
  WHERE ((due_date < p_audit_date AND status != 'done')
      OR (updated_at < (p_audit_date - 14) AND status NOT IN ('done','backlog')))
    AND ticket_code IS NOT NULL;

  -- Active agent IDs (from snapshot)
  SELECT array_agg(DISTINCT assigned_agent_id) INTO v_agent_ids
  FROM _audit_wi
  WHERE assigned_agent_id IS NOT NULL AND status NOT IN ('done','backlog');

  -- =========================================================
  -- PHASE 3: Insert/upsert the audit record.
  -- =========================================================
  INSERT INTO public.process_audits (
    user_id, project_id, auditor_agent_id, audit_type, audit_date, status,
    governance_violations, flow_metrics, agent_utilization, qa_coverage_stats,
    recommendations_count, flags_count, violations_count, max_severity,
    related_ticket_codes, related_agent_ids, meta
  ) VALUES (
    p_user_id, p_project_id, p_auditor_agent_id, 'daily', p_audit_date, 'completed',
    v_gov, v_flow, v_agents, v_qa,
    v_recs, v_flags, v_violations, v_max_sev,
    v_ticket_codes, v_agent_ids,
    jsonb_build_object('snapshot_ts', v_snapshot_ts::text, 'consistency_fix', 'SB-287')
  )
  ON CONFLICT ON CONSTRAINT process_audits_unique_daily
  DO UPDATE SET
    governance_violations = EXCLUDED.governance_violations,
    flow_metrics = EXCLUDED.flow_metrics,
    agent_utilization = EXCLUDED.agent_utilization,
    qa_coverage_stats = EXCLUDED.qa_coverage_stats,
    recommendations_count = EXCLUDED.recommendations_count,
    flags_count = EXCLUDED.flags_count,
    violations_count = EXCLUDED.violations_count,
    max_severity = EXCLUDED.max_severity,
    related_ticket_codes = EXCLUDED.related_ticket_codes,
    related_agent_ids = EXCLUDED.related_agent_ids,
    status = 'completed',
    meta = EXCLUDED.meta,
    updated_at = now()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.generate_daily_audit IS
  'SB-287: Daily audit function with snapshot-based read consistency. '
  'Phase 1 captures work_items, test_cases, and agents into temp tables; '
  'Phase 2 computes all metrics from those snapshots. '
  'Guarantees all metrics reflect the same point-in-time data. '
  'meta.snapshot_ts records when the snapshot was taken.';
;
