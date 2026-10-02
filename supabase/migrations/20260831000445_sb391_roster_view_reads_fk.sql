
-- SB-391 step 0 fallout: three views read meta.reports_to. They move to the FK
-- BEFORE the key is dropped, or dropping it silently blanks the roster and makes
-- every agent look parentless in the gaps view.
--
-- Unchanged from the previous definition except the reports_to expression.
-- Note for SB-366 / SEC-009: this view still has no security_invoker, so it runs
-- with the owner's rights. Not changed here — that is a security decision, not a
-- side effect of an org-chart migration.
create or replace view public.vw_agent_roster_status as
 SELECT a.id AS agent_id,
    a.name AS agent_name,
    a.status,
        CASE a.status
            WHEN 'active'::text THEN 'active'::text
            WHEN 'paused'::text THEN 'parked'::text
            WHEN 'disabled'::text THEN 'disabled'::text
            WHEN 'archived'::text THEN 'retired'::text
            ELSE a.status
        END AS roster_state,
    COALESCE(a.meta ->> 'tier'::text, 'unset'::text) AS tier,
    COALESCE((SELECT p.name FROM public.agents p WHERE p.id = a.reports_to_agent_id),
             a.reports_to_human) AS reports_to,
    a.meta ->> 'pm_assigned'::text AS pm_assigned,
    COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false) AS is_qa_fixture,
    a.meta ->> 'parked_reason'::text AS parked_reason,
    a.meta ->> 'parked_at'::text AS parked_at,
    ( SELECT count(*) AS count
           FROM work_items w
          WHERE w.assignee = a.name) AS items_total,
    ( SELECT count(*) AS count
           FROM work_items w
          WHERE w.assignee = a.name AND w.status = 'in_progress'::text AND NOT w.archived) AS items_in_progress,
    ( SELECT max(w.updated_at) AS max
           FROM work_items w
          WHERE w.assignee = a.name) AS last_activity,
    a.status = 'active'::text AND NOT COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false) AND NOT (EXISTS ( SELECT 1
           FROM work_items w
          WHERE w.assignee = a.name)) AS never_activated,
    COALESCE(( SELECT string_agg(DISTINCT p.project_key, '/'::text ORDER BY p.project_key) AS string_agg
           FROM agent_projects ap
             JOIN projects p ON p.id = ap.project_id
          WHERE ap.agent_id = a.id), '(none)'::text) AS projects
   FROM public.agents a
  ORDER BY (
        CASE a.status
            WHEN 'active'::text THEN 1
            WHEN 'paused'::text THEN 2
            WHEN 'disabled'::text THEN 3
            ELSE 4
        END), a.name;
;
