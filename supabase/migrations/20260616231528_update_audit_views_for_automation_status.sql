
-- audit_trend_view: only show audits for active-automation projects
CREATE OR REPLACE VIEW audit_trend_view AS
SELECT pa.audit_date,
    p.name AS project_name,
    pa.max_severity,
    pa.violations_count,
    pa.recommendations_count,
    pa.flags_count,
    (pa.flow_metrics->>'total_items')::integer AS total_items,
    (pa.flow_metrics->>'done')::integer AS done_items,
    (pa.flow_metrics->>'in_progress')::integer AS in_progress,
    (pa.flow_metrics->>'stale_14d')::integer AS stale_items,
    (pa.flow_metrics->>'overdue')::integer AS overdue_items,
    (pa.flow_metrics->>'unassigned')::integer AS unassigned_items,
    (pa.flow_metrics->>'done_today')::integer AS done_today,
    (pa.flow_metrics->>'created_today')::integer AS created_today,
    (pa.flow_metrics->>'avg_age_days')::integer AS avg_age_days,
    (pa.qa_coverage_stats->>'pass_rate')::numeric AS qa_pass_rate,
    (pa.agent_utilization->>'total_agents')::integer AS total_agents,
    (pa.agent_utilization->>'agents_with_work')::integer AS active_agents,
    pa.related_ticket_codes,
    pa.user_id
FROM process_audits pa
JOIN projects p ON p.id = pa.project_id
WHERE p.automation_status = 'active'
ORDER BY pa.audit_date DESC, p.name;

-- vw_latest_sweep_for_pe: only show sweep for active-automation projects
CREATE OR REPLACE VIEW vw_latest_sweep_for_pe AS
SELECT pa.id AS sweep_audit_id,
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
JOIN projects p ON p.id = pa.project_id
WHERE pa.audit_type = 'management_sweep'
  AND pa.audit_date = CURRENT_DATE
  AND p.automation_status = 'active'
ORDER BY pa.created_at DESC
LIMIT 1;

-- vw_daily_audit_pair: only pair audits for active-automation projects
CREATE OR REPLACE VIEW vw_daily_audit_pair AS
WITH sweep AS (
    SELECT pa.*
    FROM process_audits pa
    JOIN projects p ON p.id = pa.project_id
    WHERE pa.audit_type = 'management_sweep'
      AND pa.audit_date = CURRENT_DATE
      AND p.automation_status = 'active'
),
pe AS (
    SELECT pa.*
    FROM process_audits pa
    JOIN projects p ON p.id = pa.project_id
    WHERE pa.audit_type = 'pe_audit'
      AND pa.audit_date = CURRENT_DATE
      AND p.automation_status = 'active'
)
SELECT COALESCE(s.project_id, p.project_id) AS project_id,
    COALESCE(s.audit_date, p.audit_date) AS audit_date,
    s.id AS sweep_id,
    s.status AS sweep_status,
    s.violations_count AS sweep_violations,
    s.flags_count AS sweep_flags,
    s.max_severity AS sweep_max_severity,
    s.related_ticket_codes AS sweep_tickets_touched,
    s.meta AS sweep_meta,
    s.created_at AS sweep_ran_at,
    p.id AS pe_id,
    p.status AS pe_status,
    p.governance_violations AS pe_governance_violations,
    p.violations_count AS pe_violations,
    p.flags_count AS pe_flags,
    p.max_severity AS pe_max_severity,
    p.qa_coverage_stats AS pe_qa_stats,
    p.meta AS pe_meta,
    p.created_at AS pe_ran_at,
    CASE
        WHEN s.id IS NULL AND p.id IS NULL THEN 'neither_ran'
        WHEN s.id IS NULL THEN 'sweep_missing'
        WHEN p.id IS NULL THEN 'pe_missing'
        WHEN (p.meta->>'sweep_consumed_id')::uuid = s.id THEN 'coordinated'
        WHEN (p.meta->>'sweep_consumed_id') IS NULL THEN 'pe_ran_without_consuming_sweep'
        ELSE 'coordination_mismatch'
    END AS coordination_status,
    CASE
        WHEN 'critical' = s.max_severity OR 'critical' = p.max_severity THEN 'critical'
        WHEN 'high' = s.max_severity OR 'high' = p.max_severity THEN 'high'
        WHEN 'medium' = s.max_severity OR 'medium' = p.max_severity THEN 'medium'
        WHEN 'low' = s.max_severity OR 'low' = p.max_severity THEN 'low'
        ELSE NULL
    END AS combined_max_severity
FROM sweep s
FULL JOIN pe p ON s.project_id = p.project_id;
;
