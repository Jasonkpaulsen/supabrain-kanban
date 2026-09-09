-- SB-432. Approved by Jason 2026-09-09.
--
-- ADR-FAM-002's per-call predicate requires an agent_projects row linking the agent to
-- the REQUESTED project. Family Care Manager, Care Coordinator, School & Activities Lead
-- and Parent Advocate were assigned only to the Paulsen Family hub, while the medical and
-- school data those roles exist for lives in the child projects. Without these rows the
-- roles are startable only in the hub — which is the one place the data is not.
--
-- Two halves, because the grants differ in scope_mode:
--   Family Care Manager and School & Activities Lead are member_descendants rooted at
--   Paulsen Family, and both children are direct children of it, so the agent_projects
--   rows alone are enough for them.
--   Care Coordinator and Parent Advocate are exact_project, so each child project needs
--   its own grant row. SB-421's rule stands: a grant is only meaningful where
--   agent_projects and Mandy's membership intersect, so the rows below come first.
--
-- role = 'worker' throughout. Family Care Manager is 'owner' on the hub but owner is a
-- hub-level responsibility; it does not need to own each child project to operate in it,
-- and granting owner there would widen configuration authority for no reason.

insert into public.agent_projects (agent_id, project_id, user_id, role, scope)
select a.id, p.id, a.user_id, 'worker', 'all'
from public.agents a
cross join (values
  ('1d1a3562-f3d5-41c6-b292-0e2cc0496cb8'::uuid),  -- Kai Cyril Paulsen
  ('dd5bdbdd-158a-4e30-be40-e5451baabdd7'::uuid)   -- Jai Peter Paulsen
) as p(id)
where a.name in ('Family Care Manager','Care Coordinator','School & Activities Lead','Parent Advocate')
  and a.user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  and not exists (
    select 1 from public.agent_projects ap
     where ap.agent_id = a.id and ap.project_id = p.id
  );

-- exact_project grants for the two roles that are not descendant-scoped
insert into public.agent_operator_grants
  (external_connection_id, principal_user_id, agent_id, root_project_id,
   scope_mode, permissions, status, granted_by)
select g.external_connection_id, g.principal_user_id, g.agent_id, p.id,
       'exact_project', g.permissions, 'active', g.granted_by
from public.agent_operator_grants g
join public.agents a on a.id = g.agent_id
cross join (values
  ('1d1a3562-f3d5-41c6-b292-0e2cc0496cb8'::uuid),
  ('dd5bdbdd-158a-4e30-be40-e5451baabdd7'::uuid)
) as p(id)
where a.name in ('Care Coordinator','Parent Advocate')
  and g.scope_mode = 'exact_project'
  and g.root_project_id = 'ed8cb7f7-a604-4054-a76e-c3e1114b5316'
  and g.status = 'active'
  and not exists (
    select 1 from public.agent_operator_grants g2
     where g2.agent_id = g.agent_id
       and g2.principal_user_id = g.principal_user_id
       and g2.root_project_id = p.id
  );