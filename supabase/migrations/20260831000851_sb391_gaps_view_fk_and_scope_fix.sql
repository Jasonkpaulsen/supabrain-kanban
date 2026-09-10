
-- SB-391: the third and last consumer of meta.reports_to.
--
-- Same two changes as the violations view: the reporting-line gap is decided by
-- the foreign key, and "is this project running?" accepts either automation flag
-- so that agents the runner executes are never outside the audit. The gap logic,
-- scoring and ordering are otherwise unchanged.
create or replace view public.vw_agent_onboarding_gaps as
 WITH running_projects AS (
         SELECT p.id
           FROM projects p
          WHERE p.automation_status = 'active'::text
             OR COALESCE(p.meta ->> 'dev_automation', 'off') = 'on'
        ), agent_activity AS (
         SELECT a_1.id AS agent_id,
            max(GREATEST(COALESCE(w_name.updated_at, '1970-01-01 00:00:00+00'::timestamptz),
                         COALESCE(w_id.updated_at, '1970-01-01 00:00:00+00'::timestamptz))) AS last_activity
           FROM agents a_1
             LEFT JOIN work_items w_name ON w_name.assignee = a_1.name
             LEFT JOIN work_items w_id ON w_id.assigned_agent_id = a_1.id
          WHERE a_1.status = 'active'::text
          GROUP BY a_1.id
        ), project_management AS (
         SELECT DISTINCT ap.project_id
           FROM agent_projects ap
             JOIN agents mgr ON mgr.id = ap.agent_id
          WHERE mgr.status = 'active'::text
            AND COALESCE(mgr.meta ->> 'tier'::text, ''::text) = 'management'::text
            AND ap.project_id IN (SELECT id FROM running_projects)
        ), agent_projects_without_mgmt AS (
         SELECT ap.agent_id, array_agg(p.name ORDER BY p.name) AS uncovered_projects
           FROM agent_projects ap
             JOIN projects p ON p.id = ap.project_id
          WHERE p.id IN (SELECT id FROM running_projects)
            AND NOT (ap.project_id IN (SELECT project_id FROM project_management))
          GROUP BY ap.agent_id
        ), scored AS (
 SELECT a.id AS agent_id,
    a.name AS agent_name,
    COALESCE(a.meta ->> 'tier'::text, 'unset'::text) AS tier,
    COALESCE(a.meta ->> 'role'::text, 'unset'::text) AS role,
    COALESCE((SELECT r.name FROM agents r WHERE r.id = a.reports_to_agent_id), a.reports_to_human) AS reports_to,
    a.meta ->> 'pm_assigned'::text AS pm_assigned,
    a.created_at,
    (COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text
      AND a.reports_to_agent_id IS NULL AND a.reports_to_human IS NULL) AS gap_no_reports_to,
    ((a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text) AS gap_no_pm,
    (apm.uncovered_projects IS NOT NULL) AS gap_no_project_management,
    apm.uncovered_projects AS projects_without_management,
    (a.created_at < (now() - '14 days'::interval)
      AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamptz)) AS gap_inactive_14d,
    aa.last_activity
   FROM agents a
     LEFT JOIN agent_activity aa ON aa.agent_id = a.id
     LEFT JOIN agent_projects_without_mgmt apm ON apm.agent_id = a.id
  WHERE a.status = 'active'::text
    AND NOT COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false)
    AND NOT (EXISTS (SELECT 1 FROM agent_projects ap_chk WHERE ap_chk.agent_id = a.id)
             AND NOT EXISTS (SELECT 1 FROM agent_projects ap_act
                              WHERE ap_act.agent_id = a.id
                                AND ap_act.project_id IN (SELECT id FROM running_projects)))
        )
 SELECT agent_id, agent_name, tier, role, reports_to, pm_assigned, created_at,
    gap_no_reports_to, gap_no_pm, gap_no_project_management, projects_without_management,
    gap_inactive_14d, last_activity,
    (gap_no_reports_to::int + gap_no_pm::int + gap_no_project_management::int + gap_inactive_14d::int) AS total_gaps
   FROM scored
  WHERE gap_no_reports_to OR gap_no_pm OR gap_no_project_management OR gap_inactive_14d
  ORDER BY (CASE WHEN tier = 'apex'::text THEN 999 ELSE 0 END),
    (gap_no_reports_to::int + gap_no_pm::int + gap_no_project_management::int + gap_inactive_14d::int) DESC,
    agent_name;
;
