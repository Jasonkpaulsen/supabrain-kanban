-- SB-219 step 2: the "parked" convention.
--
-- No schema change is needed. agents_status_check already permits
-- active | paused | disabled | archived, and only 'active' and 'archived' were
-- ever used. 'paused' is adopted as the parked state: the agent is a real,
-- intentional registration that is not currently expected to do work.
--
-- Every audit view filters status='active', so parking an agent removes it from
-- the utilisation denominator automatically -- which was the whole point of the
-- ticket. It has one consequence that must be understood before parking anyone:
-- sb328_resolve_agent() also filters status='active', so a parked agent CANNOT
-- be assigned a work item. enforce_assignee_integrity will raise SB-328 on the
-- attempt. That is the intended meaning of parked, not a side effect, but it
-- means parking is a decision about whether a sub-org is live -- not a cleanup
-- chore. Unpark by setting status back to 'active'.

COMMENT ON COLUMN public.agents.status IS
'active = expected to do work and counted in utilisation. paused = PARKED (SB-219): a real registration that is not currently expected to work; excluded from all onboarding/utilisation audits, and NOT assignable -- sb328_resolve_agent filters on active, so enforce_assignee_integrity will reject a work item assigned to a parked agent. disabled = switched off due to fault or policy. archived = retired, retained for history.';

-- SB-219 step 3: report active-vs-parked instead of re-flagging cleared agents.
CREATE OR REPLACE VIEW public.vw_agent_roster_status AS
SELECT
  a.id AS agent_id,
  a.name AS agent_name,
  a.status,
  CASE a.status
    WHEN 'active'   THEN 'active'
    WHEN 'paused'   THEN 'parked'
    WHEN 'disabled' THEN 'disabled'
    WHEN 'archived' THEN 'retired'
    ELSE a.status
  END AS roster_state,
  COALESCE(a.meta->>'tier','unset')        AS tier,
  a.meta->>'reports_to'                    AS reports_to,
  a.meta->>'pm_assigned'                   AS pm_assigned,
  COALESCE((a.meta->>'qa_fixture')::boolean,false) AS is_qa_fixture,
  a.meta->>'parked_reason'                 AS parked_reason,
  a.meta->>'parked_at'                     AS parked_at,
  (SELECT count(*) FROM work_items w WHERE w.assignee = a.name) AS items_total,
  (SELECT count(*) FROM work_items w
    WHERE w.assignee = a.name AND w.status = 'in_progress' AND NOT w.archived) AS items_in_progress,
  (SELECT max(w.updated_at) FROM work_items w WHERE w.assignee = a.name) AS last_activity,
  -- 'never_activated' is the SB-219 criterion: no work item has ever carried this
  -- agent's name. Counted only for agents that are actually expected to work.
  (a.status = 'active'
   AND NOT COALESCE((a.meta->>'qa_fixture')::boolean,false)
   AND NOT EXISTS (SELECT 1 FROM work_items w WHERE w.assignee = a.name)) AS never_activated,
  COALESCE((SELECT string_agg(DISTINCT p.project_key,'/' ORDER BY p.project_key)
              FROM agent_projects ap JOIN projects p ON p.id = ap.project_id
             WHERE ap.agent_id = a.id),'(none)') AS projects
FROM agents a
ORDER BY
  CASE a.status WHEN 'active' THEN 1 WHEN 'paused' THEN 2 WHEN 'disabled' THEN 3 ELSE 4 END,
  a.name;

COMMENT ON VIEW public.vw_agent_roster_status IS
'SB-219 step 3: the roster reported as active vs parked vs disabled vs retired, so the PE audit states the shape of the roster instead of re-flagging the same dormant registrations every day. never_activated reproduces the SB-219 criterion (no work item has ever named this agent) and is scored only for agents actually expected to work -- QA fixtures and non-active agents are excluded.';;
