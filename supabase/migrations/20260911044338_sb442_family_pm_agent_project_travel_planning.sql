-- SB-442: the approved delegation path Family PM -> Travel Coordinator was not executable.
-- A delegation edge needs one project in which the parent may delegate and the child may be
-- invoked. Family PM was linked only to Paulsen Family; Travel Coordinator only to Travel
-- Planning. Linking Family PM to Travel Planning is the single missing fact.
--
-- Written as a guarded select-insert rather than a values-insert so that replaying this
-- migration into an empty database is a no-op instead of a foreign-key failure. That is the
-- SB-439 lesson applied: a data migration must not assume production rows exist.
insert into public.agent_projects (agent_id, project_id, user_id)
select a.id, p.id, a.user_id
  from public.agents a
  cross join public.projects p
 where a.id = '1b5076df-9491-4ce4-a2f6-e9f2cd636aed'   -- Family PM
   and p.id = '3f3b7473-44fb-463f-a4a0-d1fb5b9cc843'   -- Travel Planning
   and not exists (
     select 1 from public.agent_projects ap
      where ap.agent_id = a.id and ap.project_id = p.id
   );;
