
-- ============================================================
-- SB-054: Sweep/PE Coordination Protocol — Schema Support
-- ============================================================
-- Adds a CHECK constraint to standardize audit_type values,
-- a view for easy daily audit pair consumption, and
-- a helper view for the PE to read the latest sweep results.
-- ============================================================

-- 1. Add CHECK constraint to document and enforce valid audit_type values
--    'daily' = legacy/default, 'management_sweep' = JARVIS sweep, 'pe_audit' = Process Engineer audit
ALTER TABLE process_audits
  ADD CONSTRAINT chk_audit_type 
  CHECK (audit_type IN ('daily', 'management_sweep', 'pe_audit', 'ad_hoc'));

-- 2. Add COMMENT documenting the coordination contract
COMMENT ON TABLE process_audits IS 
  'Stores daily audit results from automated sweeps. Coordination protocol (SB-054): '
  'Management Sweep writes audit_type=management_sweep at ~6:45 PM. '
  'PE Audit writes audit_type=pe_audit at ~7:00 PM, consuming the sweep row via meta.sweep_consumed_id. '
  'UNIQUE(project_id, audit_type, audit_date) ensures one row per type per day.';

COMMENT ON COLUMN process_audits.audit_type IS 
  'daily=legacy default, management_sweep=JARVIS evening sweep, pe_audit=Process Engineer audit, ad_hoc=manual/one-off';

COMMENT ON COLUMN process_audits.meta IS 
  'Extensible JSONB. For management_sweep: {sweep_started_at, sweep_completed_at, tickets_advanced, tickets_blocked, escalations_raised, assignments_made, issues_resolved, sweep_version}. '
  'For pe_audit: {pe_started_at, pe_completed_at, sweep_consumed_id, sweep_review, onboarding_snapshot, governance_issues_new, pe_version}.';

-- 3. View: vw_latest_sweep_for_pe
--    The PE audit queries this at startup to consume the day's sweep results.
--    Returns the most recent management_sweep row for the current date.
CREATE OR REPLACE VIEW vw_latest_sweep_for_pe AS
SELECT 
  pa.id AS sweep_audit_id,
  pa.project_id,
  pa.auditor_agent_id,
  pa.audit_date,
  pa.status AS sweep_status,
  pa.governance_violations AS sweep_governance_violations,
  pa.flow_metrics AS sweep_flow_metrics,
  pa.agent_utilization AS sweep_agent_utilization,
  pa.recommendations_count AS sweep_recommendations,
  pa.flags_count AS sweep_flags,
  pa.violations_count AS sweep_violations,
  pa.max_severity AS sweep_max_severity,
  pa.related_ticket_codes AS sweep_ticket_codes,
  pa.related_agent_ids AS sweep_agent_ids,
  pa.meta AS sweep_meta,
  pa.created_at AS sweep_completed_at
FROM process_audits pa
WHERE pa.audit_type = 'management_sweep'
  AND pa.audit_date = CURRENT_DATE
ORDER BY pa.created_at DESC
LIMIT 1;

COMMENT ON VIEW vw_latest_sweep_for_pe IS 
  'SB-054: Returns today''s management sweep results for the PE audit to consume. '
  'If empty, the sweep hasn''t run yet — PE should flag this as an anomaly.';

-- 4. View: vw_daily_audit_pair
--    Joins today's sweep and PE audit side-by-side for morning briefing consumption.
CREATE OR REPLACE VIEW vw_daily_audit_pair AS
WITH sweep AS (
  SELECT * FROM process_audits 
  WHERE audit_type = 'management_sweep' AND audit_date = CURRENT_DATE
),
pe AS (
  SELECT * FROM process_audits 
  WHERE audit_type = 'pe_audit' AND audit_date = CURRENT_DATE
)
SELECT
  COALESCE(s.project_id, p.project_id) AS project_id,
  COALESCE(s.audit_date, p.audit_date) AS audit_date,
  -- Sweep columns
  s.id AS sweep_id,
  s.status AS sweep_status,
  s.violations_count AS sweep_violations,
  s.flags_count AS sweep_flags,
  s.max_severity AS sweep_max_severity,
  s.related_ticket_codes AS sweep_tickets_touched,
  s.meta AS sweep_meta,
  s.created_at AS sweep_ran_at,
  -- PE columns
  p.id AS pe_id,
  p.status AS pe_status,
  p.governance_violations AS pe_governance_violations,
  p.violations_count AS pe_violations,
  p.flags_count AS pe_flags,
  p.max_severity AS pe_max_severity,
  p.qa_coverage_stats AS pe_qa_stats,
  p.meta AS pe_meta,
  p.created_at AS pe_ran_at,
  -- Coordination health
  CASE 
    WHEN s.id IS NULL AND p.id IS NULL THEN 'neither_ran'
    WHEN s.id IS NULL THEN 'sweep_missing'
    WHEN p.id IS NULL THEN 'pe_missing'
    WHEN (p.meta->>'sweep_consumed_id')::uuid = s.id THEN 'coordinated'
    WHEN p.meta->>'sweep_consumed_id' IS NULL THEN 'pe_ran_without_consuming_sweep'
    ELSE 'coordination_mismatch'
  END AS coordination_status,
  -- Combined severity (worst of both)
  CASE
    WHEN 'critical' IN (s.max_severity, p.max_severity) THEN 'critical'
    WHEN 'high' IN (s.max_severity, p.max_severity) THEN 'high'
    WHEN 'medium' IN (s.max_severity, p.max_severity) THEN 'medium'
    WHEN 'low' IN (s.max_severity, p.max_severity) THEN 'low'
    ELSE NULL
  END AS combined_max_severity
FROM sweep s
FULL OUTER JOIN pe p ON s.project_id = p.project_id;

COMMENT ON VIEW vw_daily_audit_pair IS 
  'SB-054: Joins today''s Management Sweep and PE Audit side-by-side. '
  'coordination_status shows whether the PE properly consumed sweep results. '
  'Used by the morning briefing to surface overnight findings.';
;
