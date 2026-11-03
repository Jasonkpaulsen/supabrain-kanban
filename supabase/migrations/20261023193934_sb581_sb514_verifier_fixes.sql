-- SB-581, SB-514: close the three holes the independent verifier found (2026-10-23).
--
-- 1. agent_projects writes checked only user_id = auth.uid(). A viewer of a shared project
--    could link someone else's agent to it, which made can_access_agent true and, after
--    SB-581, exposed that agent's memories from every project. A link now needs the writer
--    to own the agent and to own, or be an owner or editor of, the project. Every existing
--    row already meets this (0 exceptions on 2026-10-23); only new writes are checked.
-- 2. memories writes accepted any agent_id, so a user could plant a memory in another
--    user's agent and have it read by that agent's users. agent_id must now be null, an
--    agent the writer owns, or one the writer can use. Existing rows: 0 exceptions.
-- 3. detector_field_adoption(text, text, numeric) splices p_expression into dynamic SQL and
--    was executable by anon and authenticated: any client could run its own SQL, including
--    net.http_*, which defeats SB-514. Nothing calls it as a client (no code, cron or
--    function references); it is a reporting helper for detectors run as postgres or the
--    service role, so EXECUTE now stays with those two.
-- Reads are unchanged. The policies keep their existing expressions as the first part.

create temp table sb581b_before as
select polrelid::regclass::text t, polname, polcmd, polroles, polpermissive, pg_get_expr(polqual, polrelid) q, pg_get_expr(polwithcheck, polrelid) w
  from pg_policy where polrelid in ('public.agent_projects'::regclass, 'public.memories'::regclass);

alter policy users_insert_own on public.agent_projects with check (
  (( SELECT auth.uid() AS uid) = user_id)
  AND EXISTS (SELECT 1 FROM public.agents a WHERE a.id = agent_projects.agent_id AND a.user_id = (select auth.uid()))
  AND (EXISTS (SELECT 1 FROM public.projects p WHERE p.id = agent_projects.project_id AND p.user_id = (select auth.uid()))
       OR public.member_role(project_id, (select auth.uid())) = ANY (ARRAY['owner'::text, 'editor'::text])));

alter policy users_update_own on public.agent_projects with check (
  (( SELECT auth.uid() AS uid) = user_id)
  AND EXISTS (SELECT 1 FROM public.agents a WHERE a.id = agent_projects.agent_id AND a.user_id = (select auth.uid()))
  AND (EXISTS (SELECT 1 FROM public.projects p WHERE p.id = agent_projects.project_id AND p.user_id = (select auth.uid()))
       OR public.member_role(project_id, (select auth.uid())) = ANY (ARRAY['owner'::text, 'editor'::text])));

alter policy users_insert_own on public.memories with check (
  (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM (projects p
     JOIN project_members pm ON ((pm.project_id = p.id)))
  WHERE ((p.id = memories.project_id) AND (p.shared = true) AND (pm.user_id = ( SELECT auth.uid() AS uid)) AND (pm.role = ANY (ARRAY['owner'::text, 'editor'::text])))))))
  AND (agent_id IS NULL
       OR EXISTS (SELECT 1 FROM public.agents a WHERE a.id = memories.agent_id AND a.user_id = (select auth.uid()))
       OR public.can_access_agent(agent_id, (select auth.uid()))));

alter policy users_update_own on public.memories with check (
  (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM (projects p
     JOIN project_members pm ON ((pm.project_id = p.id)))
  WHERE ((p.id = memories.project_id) AND (p.shared = true) AND (pm.user_id = ( SELECT auth.uid() AS uid)) AND (pm.role = ANY (ARRAY['owner'::text, 'editor'::text])))))))
  AND (agent_id IS NULL
       OR EXISTS (SELECT 1 FROM public.agents a WHERE a.id = memories.agent_id AND a.user_id = (select auth.uid()))
       OR public.can_access_agent(agent_id, (select auth.uid()))));

revoke all on function public.detector_field_adoption(text, text, numeric) from public, anon, authenticated;
grant execute on function public.detector_field_adoption(text, text, numeric) to service_role;
comment on function public.detector_field_adoption(text,text,numeric) is
  'SB-396: measure how widely a field is populated before a detector escalates on its absence. SB-514: p_expression is spliced into dynamic SQL, so only postgres and service_role may execute this.';

do $assert$
declare bad text; n int;
begin
  -- every policy's USING is unchanged; WITH CHECK changes only on the four rewritten policies,
  -- and each keeps its old check (the USING, where it had none) as the first part.
  select string_agg(b.t || '.' || b.polname, ', ') into bad from sb581b_before b
    left join pg_policy p on p.polrelid = b.t::regclass and p.polname = b.polname
   where p.oid is null or p.polcmd is distinct from b.polcmd or p.polroles is distinct from b.polroles
      or p.polpermissive is distinct from b.polpermissive or pg_get_expr(p.polqual, p.polrelid) is distinct from b.q
      or (case when (b.t, b.polname) in (('agent_projects', 'users_insert_own'), ('agent_projects', 'users_update_own'),
                                          ('memories', 'users_insert_own'), ('memories', 'users_update_own'))
               then strpos(pg_get_expr(p.polwithcheck, p.polrelid), coalesce(b.w, b.q)) = 0
                    or (b.polname = 'users_insert_own' and b.t = 'memories' and strpos(pg_get_expr(p.polwithcheck, p.polrelid), 'can_access_agent(agent_id, ( SELECT auth.uid() AS uid))') = 0)
                    or (b.t = 'agent_projects' and strpos(pg_get_expr(p.polwithcheck, p.polrelid), 'member_role(project_id, ( SELECT auth.uid() AS uid))') = 0)
               else pg_get_expr(p.polwithcheck, p.polrelid) is distinct from b.w end);
  if bad is not null or (select count(*) from pg_policy where polrelid in ('public.agent_projects'::regclass, 'public.memories'::regclass))
                         <> (select count(*) from sb581b_before) then
    raise exception 'SB-581b: unexpected policy change: %', coalesce(bad, 'policy count');
  end if;
  select count(*) into n from public.agent_projects ap join public.agents a on a.id = ap.agent_id join public.projects p on p.id = ap.project_id
   where a.user_id <> ap.user_id
      or (p.user_id <> ap.user_id and coalesce(public.member_role(ap.project_id, ap.user_id), '') not in ('owner', 'editor'));
  if n > 0 then raise exception 'SB-581b: % existing agent_projects rows break the new rule', n; end if;
  select count(*) into n from public.memories m join public.agents a on a.id = m.agent_id
   where a.user_id <> m.user_id and not public.can_access_agent(m.agent_id, m.user_id);
  if n > 0 then raise exception 'SB-581b: % existing agent memories break the new rule', n; end if;
  if has_function_privilege('anon', 'public.detector_field_adoption(text,text,numeric)', 'execute')
     or has_function_privilege('authenticated', 'public.detector_field_adoption(text,text,numeric)', 'execute')
     or not has_function_privilege('service_role', 'public.detector_field_adoption(text,text,numeric)', 'execute') then
    raise exception 'SB-514b: detector_field_adoption grants wrong';
  end if;
  -- the SB-514 rule, widened: no client-executable function runs dynamic SQL built with %s.
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosrc ~* '\mexecute\M' and p.prosrc ~ '%s'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'));
  if bad is not null then raise exception 'SB-514b: client-executable dynamic SQL: %', bad; end if;
end
$assert$;