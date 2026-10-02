
-- Add automation_status column to projects table
-- 'active' = included in utilization metrics, sweeps, and PE audits
-- 'paused' = excluded from metrics — project is still being built, not abandoned
ALTER TABLE projects 
ADD COLUMN IF NOT EXISTS automation_status text NOT NULL DEFAULT 'active';

-- Add check constraint
ALTER TABLE projects 
ADD CONSTRAINT chk_automation_status 
CHECK (automation_status IN ('active', 'paused'));

-- Set paused for projects Jason is still building but hasn't activated yet
-- These have zero recent completions and minimal/no active work
UPDATE projects 
SET automation_status = 'paused' 
WHERE project_key IN ('BC', 'BSC', 'RPG', 'SYL', 'FM', 'JP', '3A', 'GOV', 'WDM', 'CMP', 'MNT', 'RES', 'TRS');

-- Create helper view for other queries to use
CREATE OR REPLACE VIEW vw_active_projects AS
SELECT id, project_key, name, status, priority, domain, automation_status, parent_project_id
FROM projects
WHERE automation_status = 'active' AND archived = false;

-- Add index for fast filtering
CREATE INDEX IF NOT EXISTS idx_projects_automation_status ON projects (automation_status);
;
