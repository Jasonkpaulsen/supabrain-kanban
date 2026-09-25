
-- SB-211: Create vw_project_architecture view
-- Joins decisions with projects, filtered to accepted + non-archived
-- Uses project_key (not code) and decision (not description) per actual schema

CREATE OR REPLACE VIEW vw_project_architecture AS
SELECT 
  d.id,
  d.project_id,
  p.name AS project_name,
  p.project_key,
  d.title,
  d.domain,
  d.status,
  d.version,
  d.decision,
  d.reasoning,
  d.tags,
  d.meta,
  d.work_item_id,
  d.supersedes_id,
  d.created_at,
  d.updated_at
FROM decisions d
JOIN projects p ON d.project_id = p.id
WHERE d.status = 'accepted'
  AND d.archived = false
ORDER BY p.project_key, d.domain, d.version DESC;
;
