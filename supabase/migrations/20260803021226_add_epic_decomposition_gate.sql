
-- View: surfaces all epics with zero children (the daily PE audit can query this)
CREATE OR REPLACE VIEW v_empty_epics AS
SELECT 
  wi.id,
  wi.ticket_code,
  wi.title,
  wi.status,
  wi.project_id,
  p.name AS project_name,
  p.status AS project_status,
  wi.created_at,
  wi.updated_at,
  -- Grace: how many hours since creation
  EXTRACT(EPOCH FROM (now() - wi.created_at)) / 3600 AS hours_since_created,
  -- Flag if past 48h grace window
  CASE WHEN EXTRACT(EPOCH FROM (now() - wi.created_at)) / 3600 > 48 
       THEN true ELSE false END AS grace_expired
FROM work_items wi
JOIN projects p ON wi.project_id = p.id
LEFT JOIN work_items children ON children.parent_id = wi.id
WHERE wi.type = 'epic'
  AND wi.status NOT IN ('done', 'cancelled')
  AND p.status = 'active'
  AND (wi.meta->>'catch_all')::text IS DISTINCT FROM 'true'
GROUP BY wi.id, wi.ticket_code, wi.title, wi.status, wi.project_id, 
         p.name, p.status, wi.created_at, wi.updated_at
HAVING count(children.id) = 0
ORDER BY grace_expired DESC, wi.created_at ASC;

-- Comment for discoverability
COMMENT ON VIEW v_empty_epics IS 'SB-297: Surfaces active epics with zero child tickets. grace_expired=true means the 48h decomposition window has passed. Used by the daily PE audit.';
;
