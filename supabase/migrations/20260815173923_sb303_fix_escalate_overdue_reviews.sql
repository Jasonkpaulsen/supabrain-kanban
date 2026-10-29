
-- Drop and recreate escalate_overdue_reviews with matching return type
DROP FUNCTION IF EXISTS escalate_overdue_reviews(uuid);

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
