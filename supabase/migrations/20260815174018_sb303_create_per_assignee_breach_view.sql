
-- SB-303: Per-assignee breach summary for daily sweeps (PE daily + JARVIS)
CREATE OR REPLACE VIEW v_review_breaches_by_assignee AS
SELECT
  assignee,
  count(*) AS total_breaches,
  count(*) FILTER (WHERE breach_level = 'hard') AS hard_breaches,
  count(*) FILTER (WHERE breach_level = 'soft') AS soft_breaches,
  max(hours_in_review) AS worst_hours,
  jsonb_agg(jsonb_build_object(
    'ticket', ticket_code,
    'title', title,
    'hours', hours_in_review,
    'level', breach_level,
    'project', project_key
  ) ORDER BY hours_in_review DESC) AS items
FROM v_review_sla_breaches
GROUP BY assignee
ORDER BY max(CASE WHEN breach_level = 'hard' THEN 1 ELSE 2 END),
         max(hours_in_review) DESC;

COMMENT ON VIEW v_review_breaches_by_assignee IS 'SB-303: Groups SLA breaches by assignee/PM for daily sweep consumption.';
;
