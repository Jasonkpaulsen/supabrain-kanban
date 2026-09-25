-- Add domain column to projects for personal/professional/family isolation
ALTER TABLE projects ADD COLUMN domain TEXT NOT NULL DEFAULT 'professional'
  CHECK (domain IN ('professional', 'personal', 'family'));

CREATE INDEX idx_projects_domain ON projects (domain);

COMMENT ON COLUMN projects.domain IS 'Scope boundary: professional (work/business), personal (self/hobbies), family (household/kids/travel). Agents and queries should respect this boundary unless explicitly asked to cross it.';;
