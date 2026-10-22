-- SB-625: vw_agent_onboarding_gaps decides "running" by automation_status alone.
--
-- SB-391 (20260831000851) let either flag count, so that no agent the runner executes was
-- outside the audit. Since SB-390 the runner reads only automation_status, and since SB-623
-- the board toggle writes only automation_status, so a stale meta.dev_automation = 'on'
-- made the view audit agents on projects the runner skips. The body below is the live
-- definition with that one predicate changed; columns, gap logic, ordering, security_invoker
-- and grants are unchanged.
--
-- The view was the last reader of meta.dev_automation, so the retired key is removed from
-- the projects that still carry it (one, today). Other meta keys are untouched.
create or replace view public.vw_agent_onboarding_gaps with (security_invoker = true) as
 WITH running_projects AS (
         SELECT p.id
           FROM projects p
          WHERE p.automation_status = 'active'::text
        ), agent_activity AS (
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
          WHERE mgr.status = 'active'::text AND COALESCE(mgr.meta ->> 'tier'::text, ''::text) = 'management'::text AND (ap.project_id IN ( SELECT running_projects.id
                   FROM running_projects))
        ), agent_projects_without_mgmt AS (
         SELECT ap.agent_id,
            array_agg(p.name ORDER BY p.name) AS uncovered_projects
           FROM agent_projects ap
             JOIN projects p ON p.id = ap.project_id
          WHERE (p.id IN ( SELECT running_projects.id
                   FROM running_projects)) AND NOT (ap.project_id IN ( SELECT project_management.project_id
                   FROM project_management))
          GROUP BY ap.agent_id
        ), scored AS (
         SELECT a.id AS agent_id,
            a.name AS agent_name,
            COALESCE(a.meta ->> 'tier'::text, 'unset'::text) AS tier,
            COALESCE(a.meta ->> 'role'::text, 'unset'::text) AS role,
            COALESCE(( SELECT r.name
                   FROM agents r
                  WHERE r.id = a.reports_to_agent_id), a.reports_to_human) AS reports_to,
            a.meta ->> 'pm_assigned'::text AS pm_assigned,
            a.created_at,
            COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text AND a.reports_to_agent_id IS NULL AND a.reports_to_human IS NULL AS gap_no_reports_to,
            (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text AS gap_no_pm,
            apm.uncovered_projects IS NOT NULL AS gap_no_project_management,
            apm.uncovered_projects AS projects_without_management,
            a.created_at < (now() - '14 days'::interval) AND (aa.last_activity IS NULL OR aa.last_activity = '1970-01-01 00:00:00+00'::timestamp with time zone) AS gap_inactive_14d,
            aa.last_activity
           FROM agents a
             LEFT JOIN agent_activity aa ON aa.agent_id = a.id
             LEFT JOIN agent_projects_without_mgmt apm ON apm.agent_id = a.id
          WHERE a.status = 'active'::text AND NOT COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false) AND NOT ((EXISTS ( SELECT 1
                   FROM agent_projects ap_chk
                  WHERE ap_chk.agent_id = a.id)) AND NOT (EXISTS ( SELECT 1
                   FROM agent_projects ap_act
                  WHERE ap_act.agent_id = a.id AND (ap_act.project_id IN ( SELECT running_projects.id
                           FROM running_projects)))))
        )
 SELECT agent_id,
    agent_name,
    tier,
    role,
    reports_to,
    pm_assigned,
    created_at,
    gap_no_reports_to,
    gap_no_pm,
    gap_no_project_management,
    projects_without_management,
    gap_inactive_14d,
    last_activity,
    gap_no_reports_to::integer + gap_no_pm::integer + gap_no_project_management::integer + gap_inactive_14d::integer AS total_gaps
   FROM scored
  WHERE gap_no_reports_to OR gap_no_pm OR gap_no_project_management OR gap_inactive_14d
  ORDER BY (
        CASE
            WHEN tier = 'apex'::text THEN 999
            ELSE 0
        END), (gap_no_reports_to::integer + gap_no_pm::integer + gap_no_project_management::integer + gap_inactive_14d::integer) DESC, agent_name;

update public.projects set meta = meta - 'dev_automation' where meta ? 'dev_automation';

do $assert$
begin
  if strpos(pg_get_viewdef('public.vw_agent_onboarding_gaps'::regclass), 'dev_automation') > 0 then
    raise exception 'SB-625: vw_agent_onboarding_gaps still reads dev_automation';
  end if;
  if (select coalesce(reloptions, '{}') from pg_class where oid = 'public.vw_agent_onboarding_gaps'::regclass)
     is distinct from '{security_invoker=true}'::text[] then
    raise exception 'SB-625: vw_agent_onboarding_gaps lost security_invoker';
  end if;
  if (select relacl::text from pg_class where oid = 'public.vw_agent_onboarding_gaps'::regclass)
     is distinct from '{postgres=arwdDxtm/postgres,authenticated=rm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'SB-625: vw_agent_onboarding_gaps grants changed';
  end if;
  if exists (select 1 from public.projects where meta ? 'dev_automation') then
    raise exception 'SB-625: a project still carries meta.dev_automation';
  end if;
end
$assert$;
