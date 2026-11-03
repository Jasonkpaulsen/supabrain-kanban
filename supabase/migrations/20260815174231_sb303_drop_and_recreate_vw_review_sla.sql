
-- Must drop function first (depends on view), then view, then recreate both
DROP FUNCTION IF EXISTS escalate_overdue_reviews(uuid);
DROP VIEW IF EXISTS vw_review_sla;

CREATE VIEW vw_review_sla AS
SELECT
  w.id,
  w.ticket_code,
  w.title,
  w.type,
  w.priority,
  w.assignee,
  w.review_entered_at,
  w.project_id,
  round((EXTRACT(epoch FROM (now() - w.review_entered_at)) / 3600.0)::numeric, 1) AS hours_in_review,
  CASE
    WHEN (EXTRACT(epoch FROM (now() - w.review_entered_at)) / 3600.0) >= 48 THEN true
    ELSE false
  END AS sla_breached,
  CASE
    WHEN (EXTRACT(epoch FROM (now() - w.review_entered_at)) / 3600.0) >= 72 THEN 'HARD_BREACH'
    WHEN (EXTRACT(epoch FROM (now() - w.review_entered_at)) / 3600.0) >= 48 THEN 'SOFT_BREACH'
    WHEN (EXTRACT(epoch FROM (now() - w.review_entered_at)) / 3600.0) >= 36 THEN 'AT_RISK'
    ELSE 'OK'
  END AS sla_status,
  w.authority_level,
  p.name AS project_name,
  p.project_key
FROM work_items w
JOIN projects p ON p.id = w.project_id
WHERE w.status = 'review';

COMMENT ON VIEW vw_review_sla IS 'SB-303: Review SLA view — 48h soft breach, 72h hard breach, 36h at-risk warning.';

CREATE FUNCTION escalate_overdue_reviews(p_user_id uuid DEFAULT NULL)
RETURNS TABLE(
  ticket_code text,
  title text,
  hours_in_review numeric,
  sla_status text,
  assignee text,
  project_name text
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT
    v.ticket_code,
    v.title,
    v.hours_in_review,
    v.sla_status,
    v.assignee,
    v.project_name
  FROM vw_review_sla v
  JOIN work_items w ON w.id = v.id
  WHERE v.sla_breached = true
    AND (p_user_id IS NULL OR w.user_id = p_user_id)
  ORDER BY v.hours_in_review DESC;
END;
$$;
;
