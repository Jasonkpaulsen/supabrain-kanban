
-- SB-303: Add review_wip_limit column to projects
ALTER TABLE projects ADD COLUMN review_wip_limit integer DEFAULT NULL;
COMMENT ON COLUMN projects.review_wip_limit IS 'SB-303: Max items allowed in review status per project. NULL = unlimited.';

-- Set default review_wip_limit for active dev projects
UPDATE projects SET review_wip_limit = 5
WHERE project_key IN ('CIP', 'DEN', 'CS', 'SB')
  AND archived = false;
;
