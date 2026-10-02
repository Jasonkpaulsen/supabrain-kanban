
-- SB-050: Agent onboarding governance — standing audit view
-- Identifies agents with structural governance gaps:
--   1. No reports_to chain (and not apex tier)
--   2. No management-tier agent in their project(s)
--   3. Created >14 days ago with zero work activity
-- Complements existing vw_agent_onboarding_violations (field-level checks)
-- This is a reporting/visibility tool, NOT an enforcement trigger.

CREATE OR REPLACE VIEW vw_agent_onboarding_gaps AS
WITH agent_activity AS (
  -- Most recent work activity per agent (via assignee name or assigned_agent_id)
  SELECT 
    a.id AS agent_id,
    MAX(GREATEST(
      COALESCE(w_name.updated_at, '1970-01-01'::timestamptz),
      COALESCE(w_id.updated_at, '1970-01-01'::timestamptz)
    )) AS last_activity
  FROM agents a
  LEFT JOIN work_items w_name ON w_name.assignee = a.name
  LEFT JOIN work_items w_id ON w_id.assigned_agent_id = a.id
  WHERE a.status = 'active'
  GROUP BY a.id
),
project_management AS (
  -- Projects that have at least one management-tier agent
  SELECT DISTINCT ap.project_id
  FROM agent_projects ap
  JOIN agents mgr ON mgr.id = ap.agent_id
  WHERE mgr.status = 'active'
    AND COALESCE(mgr.meta->>'tier', '') = 'management'
),
agent_projects_without_mgmt AS (
  -- Agents assigned to projects with no management-tier coverage
  SELECT ap.agent_id, 
    array_agg(p.name ORDER BY p.name) AS uncovered_projects
  FROM agent_projects ap
  JOIN projects p ON p.id = ap.project_id
  WHERE ap.project_id NOT IN (SELECT project_id FROM project_management)
  GROUP BY ap.agent_id
)
SELECT 
  a.id AS agent_id,
  a.name AS agent_name,
  COALESCE(a.meta->>'tier', 'unset') AS tier,
  COALESCE(a.meta->>'role', 'unset') AS role,
  a.meta->>'reports_to' AS reports_to,
  a.meta->>'pm_assigned' AS pm_assigned,
  a.created_at,

  -- Gap 1: No reporting chain (non-apex agents)
  CASE 
    WHEN COALESCE(a.meta->>'tier', '') != 'apex'
      AND (a.meta->>'reports_to' IS NULL OR TRIM(a.meta->>'reports_to') = '')
    THEN true ELSE false
  END AS gap_no_reports_to,

  -- Gap 2: No PM coverage
  CASE 
    WHEN a.meta->>'pm_assigned' IS NULL OR TRIM(a.meta->>'pm_assigned') = ''
    THEN true ELSE false
  END AS gap_no_pm,

  -- Gap 3: No management-tier agent in their project(s)
  CASE 
    WHEN apm.uncovered_projects IS NOT NULL
    THEN true ELSE false
  END AS gap_no_project_management,
  apm.uncovered_projects AS projects_without_management,

  -- Gap 4: Created >14 days ago with no work activity
  CASE 
    WHEN a.created_at < (NOW() - interval '14 days')
      AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01'::timestamptz)
    THEN true ELSE false
  END AS gap_inactive_14d,
  aa.last_activity,

  -- Summary
  CASE 
    WHEN COALESCE(a.meta->>'tier', '') != 'apex'
      AND (a.meta->>'reports_to' IS NULL OR TRIM(a.meta->>'reports_to') = '')
    THEN 1 ELSE 0
  END
  + CASE WHEN a.meta->>'pm_assigned' IS NULL OR TRIM(a.meta->>'pm_assigned') = '' THEN 1 ELSE 0 END
  + CASE WHEN apm.uncovered_projects IS NOT NULL THEN 1 ELSE 0 END
  + CASE 
      WHEN a.created_at < (NOW() - interval '14 days')
        AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01'::timestamptz)
      THEN 1 ELSE 0
    END AS total_gaps

FROM agents a
LEFT JOIN agent_activity aa ON aa.agent_id = a.id
LEFT JOIN agent_projects_without_mgmt apm ON apm.agent_id = a.id
WHERE a.status = 'active'
  AND (
    -- Include agents with at least one gap
    (COALESCE(a.meta->>'tier', '') != 'apex' AND (a.meta->>'reports_to' IS NULL OR TRIM(a.meta->>'reports_to') = ''))
    OR (a.meta->>'pm_assigned' IS NULL OR TRIM(a.meta->>'pm_assigned') = '')
    OR apm.uncovered_projects IS NOT NULL
    OR (a.created_at < (NOW() - interval '14 days') AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01'::timestamptz))
  )
ORDER BY 
  CASE WHEN COALESCE(a.meta->>'tier', '') = 'apex' THEN 999 ELSE 0 END,
  total_gaps DESC,
  a.name;

COMMENT ON VIEW vw_agent_onboarding_gaps IS 
  'SB-050: Standing audit view for agent onboarding governance gaps. '
  'Identifies agents missing: reports_to chain, PM coverage, management-tier project coverage, '
  'or with >14 days of inactivity since creation. Reporting/visibility only — not enforcement.';
;
