
-- Update vw_agent_onboarding_gaps:
-- 1. Exclude agents assigned ONLY to paused projects
-- 2. project_management CTE only checks active projects
-- 3. agent_projects_without_mgmt CTE only checks active projects
CREATE OR REPLACE VIEW vw_agent_onboarding_gaps AS
WITH agent_activity AS (
    SELECT a_1.id AS agent_id,
        max(GREATEST(
            COALESCE(w_name.updated_at, '1970-01-01 00:00:00+00'::timestamptz),
            COALESCE(w_id.updated_at, '1970-01-01 00:00:00+00'::timestamptz)
        )) AS last_activity
    FROM agents a_1
    LEFT JOIN work_items w_name ON w_name.assignee = a_1.name
    LEFT JOIN work_items w_id ON w_id.assigned_agent_id = a_1.id
    WHERE a_1.status = 'active'
    GROUP BY a_1.id
),
project_management AS (
    SELECT DISTINCT ap.project_id
    FROM agent_projects ap
    JOIN agents mgr ON mgr.id = ap.agent_id
    JOIN projects p ON p.id = ap.project_id
    WHERE mgr.status = 'active'
      AND COALESCE(mgr.meta->>'tier', '') = 'management'
      AND p.automation_status = 'active'
),
agent_projects_without_mgmt AS (
    SELECT ap.agent_id,
        array_agg(p.name ORDER BY p.name) AS uncovered_projects
    FROM agent_projects ap
    JOIN projects p ON p.id = ap.project_id
    WHERE p.automation_status = 'active'
      AND NOT (ap.project_id IN (SELECT project_id FROM project_management))
    GROUP BY ap.agent_id
)
SELECT a.id AS agent_id,
    a.name AS agent_name,
    COALESCE(a.meta->>'tier', 'unset') AS tier,
    COALESCE(a.meta->>'role', 'unset') AS role,
    a.meta->>'reports_to' AS reports_to,
    a.meta->>'pm_assigned' AS pm_assigned,
    a.created_at,
    CASE
        WHEN COALESCE(a.meta->>'tier', '') <> 'apex'
            AND ((a.meta->>'reports_to') IS NULL OR TRIM(a.meta->>'reports_to') = '')
        THEN true ELSE false
    END AS gap_no_reports_to,
    CASE
        WHEN (a.meta->>'pm_assigned') IS NULL OR TRIM(a.meta->>'pm_assigned') = ''
        THEN true ELSE false
    END AS gap_no_pm,
    CASE
        WHEN apm.uncovered_projects IS NOT NULL THEN true ELSE false
    END AS gap_no_project_management,
    apm.uncovered_projects AS projects_without_management,
    CASE
        WHEN a.created_at < (now() - interval '14 days')
            AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamptz)
        THEN true ELSE false
    END AS gap_inactive_14d,
    aa.last_activity,
    (
        CASE WHEN COALESCE(a.meta->>'tier','') <> 'apex'
            AND ((a.meta->>'reports_to') IS NULL OR TRIM(a.meta->>'reports_to') = '')
            THEN 1 ELSE 0 END
      + CASE WHEN (a.meta->>'pm_assigned') IS NULL OR TRIM(a.meta->>'pm_assigned') = ''
            THEN 1 ELSE 0 END
      + CASE WHEN apm.uncovered_projects IS NOT NULL
            THEN 1 ELSE 0 END
      + CASE WHEN a.created_at < (now() - interval '14 days')
            AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamptz)
            THEN 1 ELSE 0 END
    ) AS total_gaps
FROM agents a
LEFT JOIN agent_activity aa ON aa.agent_id = a.id
LEFT JOIN agent_projects_without_mgmt apm ON apm.agent_id = a.id
WHERE a.status = 'active'
  -- Exclude agents assigned ONLY to paused projects
  AND NOT (
    EXISTS (SELECT 1 FROM agent_projects ap_chk WHERE ap_chk.agent_id = a.id)
    AND NOT EXISTS (
      SELECT 1 FROM agent_projects ap_act
      JOIN projects p_act ON p_act.id = ap_act.project_id
      WHERE ap_act.agent_id = a.id AND p_act.automation_status = 'active'
    )
  )
  AND (
    (COALESCE(a.meta->>'tier','') <> 'apex'
      AND ((a.meta->>'reports_to') IS NULL OR TRIM(a.meta->>'reports_to') = ''))
    OR ((a.meta->>'pm_assigned') IS NULL OR TRIM(a.meta->>'pm_assigned') = '')
    OR apm.uncovered_projects IS NOT NULL
    OR (a.created_at < (now() - interval '14 days')
        AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamptz))
  )
ORDER BY
    CASE WHEN COALESCE(a.meta->>'tier','') = 'apex' THEN 999 ELSE 0 END,
    (
        CASE WHEN COALESCE(a.meta->>'tier','') <> 'apex'
            AND ((a.meta->>'reports_to') IS NULL OR TRIM(a.meta->>'reports_to') = '')
            THEN 1 ELSE 0 END
      + CASE WHEN (a.meta->>'pm_assigned') IS NULL OR TRIM(a.meta->>'pm_assigned') = ''
            THEN 1 ELSE 0 END
      + CASE WHEN apm.uncovered_projects IS NOT NULL
            THEN 1 ELSE 0 END
      + CASE WHEN a.created_at < (now() - interval '14 days')
            AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamptz)
            THEN 1 ELSE 0 END
    ) DESC,
    a.name;
;
