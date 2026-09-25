-- SB-219: the audit re-flags QA fixture agents forever. They are test scaffolding
-- (meta.qa_fixture = true), not org members -- they have no tier, no reporting line
-- and no PM by design, and inventing one for them would be a lie in the hierarchy.
-- Excluded from the gaps audit rather than backfilled. Only the WHERE clause changes.
CREATE OR REPLACE VIEW public.vw_agent_onboarding_gaps AS
 WITH agent_activity AS (
         SELECT a_1.id AS agent_id,
            max(GREATEST(COALESCE(w_name.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(w_id.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone))) AS last_activity
           FROM agents a_1
             LEFT JOIN work_items w_name ON w_name.assignee = a_1.name
             LEFT JOIN work_items w_id ON w_id.assigned_agent_id = a_1.id
          WHERE a_1.status = 'active'::text
          GROUP BY a_1.id
        ), project_management AS (
         SELECT DISTINCT ap.project_id
           FROM agent_projects ap
             JOIN agents mgr ON mgr.id = ap.agent_id
             JOIN projects p ON p.id = ap.project_id
          WHERE mgr.status = 'active'::text AND COALESCE(mgr.meta ->> 'tier'::text, ''::text) = 'management'::text AND p.automation_status = 'active'::text
        ), agent_projects_without_mgmt AS (
         SELECT ap.agent_id,
            array_agg(p.name ORDER BY p.name) AS uncovered_projects
           FROM agent_projects ap
             JOIN projects p ON p.id = ap.project_id
          WHERE p.automation_status = 'active'::text AND NOT (ap.project_id IN ( SELECT project_management.project_id
                   FROM project_management))
          GROUP BY ap.agent_id
        )
 SELECT a.id AS agent_id,
    a.name AS agent_name,
    COALESCE(a.meta ->> 'tier'::text, 'unset'::text) AS tier,
    COALESCE(a.meta ->> 'role'::text, 'unset'::text) AS role,
    a.meta ->> 'reports_to'::text AS reports_to,
    a.meta ->> 'pm_assigned'::text AS pm_assigned,
    a.created_at,
        CASE
            WHEN COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text AND ((a.meta ->> 'reports_to'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'reports_to'::text) = ''::text) THEN true
            ELSE false
        END AS gap_no_reports_to,
        CASE
            WHEN (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text THEN true
            ELSE false
        END AS gap_no_pm,
        CASE
            WHEN apm.uncovered_projects IS NOT NULL THEN true
            ELSE false
        END AS gap_no_project_management,
    apm.uncovered_projects AS projects_without_management,
        CASE
            WHEN a.created_at < (now() - '14 days'::interval) AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamp with time zone) THEN true
            ELSE false
        END AS gap_inactive_14d,
    aa.last_activity,
        CASE
            WHEN COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text AND ((a.meta ->> 'reports_to'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'reports_to'::text) = ''::text) THEN 1
            ELSE 0
        END +
        CASE
            WHEN (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text THEN 1
            ELSE 0
        END +
        CASE
            WHEN apm.uncovered_projects IS NOT NULL THEN 1
            ELSE 0
        END +
        CASE
            WHEN a.created_at < (now() - '14 days'::interval) AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamp with time zone) THEN 1
            ELSE 0
        END AS total_gaps
   FROM agents a
     LEFT JOIN agent_activity aa ON aa.agent_id = a.id
     LEFT JOIN agent_projects_without_mgmt apm ON apm.agent_id = a.id
  WHERE a.status = 'active'::text
    AND NOT COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false)   -- SB-219
    AND NOT ((EXISTS ( SELECT 1
           FROM agent_projects ap_chk
          WHERE ap_chk.agent_id = a.id)) AND NOT (EXISTS ( SELECT 1
           FROM agent_projects ap_act
             JOIN projects p_act ON p_act.id = ap_act.project_id
          WHERE ap_act.agent_id = a.id AND p_act.automation_status = 'active'::text)))
    AND (COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text AND ((a.meta ->> 'reports_to'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'reports_to'::text) = ''::text) OR (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text OR apm.uncovered_projects IS NOT NULL OR a.created_at < (now() - '14 days'::interval) AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamp with time zone))
  ORDER BY (
        CASE
            WHEN COALESCE(a.meta ->> 'tier'::text, ''::text) = 'apex'::text THEN 999
            ELSE 0
        END), (
        CASE
            WHEN COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text AND ((a.meta ->> 'reports_to'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'reports_to'::text) = ''::text) THEN 1
            ELSE 0
        END +
        CASE
            WHEN (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text THEN 1
            ELSE 0
        END +
        CASE
            WHEN apm.uncovered_projects IS NOT NULL THEN 1
            ELSE 0
        END +
        CASE
            WHEN a.created_at < (now() - '14 days'::interval) AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamp with time zone) THEN 1
            ELSE 0
        END) DESC, a.name;;
