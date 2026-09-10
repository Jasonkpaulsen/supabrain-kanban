
-- SB-215: Fix audit predicate false positive
-- The stored functions (generate_daily_audit, enforce_approval_gate) already correctly
-- use: approval_status NOT IN ('approved', 'not_required')
-- 
-- The false positive comes from ad-hoc audit queries that only check for 'approved'.
-- This migration creates a standing view with the CORRECT predicate so the Process
-- Engineer (and any ad-hoc query) can reference it instead of writing raw SQL.
--
-- CORRECT predicate for governance compliance:
--   approval_status IN ('approved', 'not_required')  →  compliant
--   approval_status = 'pending'                      →  violation (if in active state)

CREATE OR REPLACE VIEW vw_approval_compliance AS
SELECT 
  w.id,
  w.ticket_code,
  w.title,
  w.status,
  w.type,
  w.approval_status,
  w.authority_level,
  w.assignee,
  w.approved_by,
  w.approved_at,
  w.created_at,
  w.updated_at,
  CASE 
    WHEN w.approval_status IN ('approved', 'not_required') THEN true
    ELSE false
  END AS is_compliant,
  CASE
    WHEN w.status IN ('in_progress', 'review', 'done') 
         AND w.approval_status NOT IN ('approved', 'not_required')
    THEN 'VIOLATION: Active ticket without approval (status=' || w.status || ', approval_status=' || w.approval_status || ')'
    ELSE NULL
  END AS violation_detail
FROM work_items w;

COMMENT ON VIEW vw_approval_compliance IS 
  'SB-215: Standing audit view for approval compliance. '
  'Treats both approved AND not_required as compliant. '
  'Use: SELECT * FROM vw_approval_compliance WHERE violation_detail IS NOT NULL '
  'to find genuine governance violations. Do NOT use approval_status != approved alone.';
;
