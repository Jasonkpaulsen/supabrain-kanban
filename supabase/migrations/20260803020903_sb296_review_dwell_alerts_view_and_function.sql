
-- v_review_dwell_alerts: surfaces items in review >24h with tiered breach levels
-- Complements v_review_sla_breaches (SB-254) which starts at 48h.
-- This view adds the earlier 24h warning tier for JARVIS sweep pre-escalation.
CREATE OR REPLACE VIEW v_review_dwell_alerts AS
SELECT
    wi.id,
    wi.ticket_code,
    wi.title,
    p.project_key,
    wi.assignee,
    wi.user_id,
    wi.review_entered_at,
    round(EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600, 1) AS hours_in_review,
    CASE
        WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600) >= 72 THEN 'hard_breach'
        WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600) >= 48 THEN 'soft_breach'
        ELSE 'warning'
    END AS breach_level,
    CASE
        WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600) >= 72 THEN 1
        WHEN (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600) >= 48 THEN 2
        ELSE 3
    END AS severity_rank
FROM work_items wi
JOIN projects p ON p.id = wi.project_id
WHERE wi.status = 'review'
  AND wi.review_entered_at IS NOT NULL
  AND (EXTRACT(epoch FROM now() - wi.review_entered_at) / 3600) >= 24
  AND p.archived = false
  AND p.automation_status <> 'paused'
ORDER BY severity_rank ASC, hours_in_review DESC;

-- get_review_alerts(): RPC function for JARVIS sweep to call
CREATE OR REPLACE FUNCTION get_review_alerts(
    min_hours numeric DEFAULT 24,
    target_project_key text DEFAULT NULL
)
RETURNS TABLE (
    item_id uuid,
    ticket_code text,
    title text,
    project_key text,
    assignee text,
    hours_in_review numeric,
    breach_level text,
    severity_rank integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT
        id AS item_id,
        ticket_code,
        title,
        project_key,
        assignee,
        hours_in_review,
        breach_level,
        severity_rank
    FROM v_review_dwell_alerts
    WHERE hours_in_review >= min_hours
      AND (target_project_key IS NULL OR v_review_dwell_alerts.project_key = target_project_key)
    ORDER BY severity_rank ASC, hours_in_review DESC;
$$;
;
