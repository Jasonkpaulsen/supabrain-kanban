
-- SB-232: WIP-aging + review/approval-leak checks for PE daily audit

-- 1. v_wip_aging_alerts: in_progress items idle >3 days + per-assignee over-WIP counts
CREATE OR REPLACE VIEW v_wip_aging_alerts AS
WITH idle_wip AS (
  SELECT
    wi.id,
    wi.ticket_code,
    wi.title,
    wi.type,
    wi.status,
    wi.priority,
    wi.assignee,
    wi.updated_at,
    p.project_key,
    p.name AS project_name,
    EXTRACT(DAY FROM now() - wi.updated_at)::int AS idle_days,
    'idle_wip' AS alert_type
  FROM work_items wi
  JOIN projects p ON p.id = wi.project_id
  WHERE wi.status = 'in_progress'
    AND wi.updated_at < now() - interval '3 days'
),
over_wip AS (
  SELECT
    wi.assignee,
    COUNT(*) AS current_wip,
    wl.max_wip,
    COUNT(*) - wl.max_wip AS over_by,
    'over_wip' AS alert_type
  FROM work_items wi
  JOIN wip_limits wl ON wl.assignee = wi.assignee
  WHERE wi.status = 'in_progress'
  GROUP BY wi.assignee, wl.max_wip
  HAVING COUNT(*) > wl.max_wip
)
-- Idle WIP items
SELECT
  iw.id,
  iw.ticket_code,
  iw.title,
  iw.type,
  iw.status,
  iw.priority,
  iw.assignee,
  iw.updated_at,
  iw.project_key,
  iw.project_name,
  iw.idle_days,
  iw.alert_type,
  NULL::int AS current_wip,
  NULL::int AS max_wip,
  NULL::int AS over_by
FROM idle_wip iw

UNION ALL

-- Per-assignee over-WIP (one row per assignee)
SELECT
  NULL::uuid,
  NULL,
  'Assignee over WIP limit: ' || ow.assignee,
  NULL,
  NULL,
  NULL,
  ow.assignee,
  NULL::timestamptz,
  NULL,
  NULL,
  NULL::int,
  ow.alert_type,
  ow.current_wip::int,
  ow.max_wip::int,
  ow.over_by::int
FROM over_wip ow

ORDER BY alert_type, idle_days DESC NULLS LAST;


-- 2. v_gate_leak_alerts: items in done without review, or with pending approval
CREATE OR REPLACE VIEW v_gate_leak_alerts AS
SELECT
  wi.id,
  wi.ticket_code,
  wi.title,
  wi.type,
  wi.status,
  wi.assignee,
  p.project_key,
  p.name AS project_name,
  wi.review_entered_at,
  wi.review_completed_at,
  wi.approval_status,
  wi.approved_by,
  wi.approved_at,
  wi.completed_at,
  CASE
    WHEN wi.review_entered_at IS NULL THEN 'missing_review'
    WHEN wi.approval_status = 'pending' THEN 'pending_approval'
    WHEN wi.approval_status = 'awaiting' THEN 'awaiting_approval'
  END AS leak_type
FROM work_items wi
JOIN projects p ON p.id = wi.project_id
WHERE wi.status = 'done'
  AND (
    wi.review_entered_at IS NULL
    OR wi.approval_status IN ('pending','awaiting')
  )
ORDER BY
  CASE
    WHEN wi.review_entered_at IS NULL THEN 0
    ELSE 1
  END,
  wi.completed_at DESC;
;
