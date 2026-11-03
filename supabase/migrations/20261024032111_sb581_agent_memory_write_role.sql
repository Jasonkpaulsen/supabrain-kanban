-- SB-581: writing into an agent's recall needs a write role, not just read access (re-verify, 2026-10-23).
--
-- 20261023193934 let a memory carry any agent the writer can use. Viewers can use the agents
-- linked to their project, so a viewer could tag their own memory with that agent and every
-- other user of the agent would recall it. Tagging now needs the writer to own the agent, or
-- to own or edit (owner/editor role, or projects.user_id) a project the agent is linked to:
-- the same bar as writing into that project. Reading is unchanged.
--
-- Accepted cost, measured: an editor cannot edit a memory in their project when it carries
-- an agent they could not tag with (a WITH CHECK cannot see the old agent_id). On 2026-10-23
-- that is 0 of 31 (editor, agent memory) pairs, and 0 existing rows break the new rule.

create temp table sb581c_before as
select polname, polcmd, polroles, polpermissive, pg_get_expr(polqual, polrelid) q, pg_get_expr(polwithcheck, polrelid) w
  from pg_policy where polrelid = 'public.memories'::regclass;

alter policy users_insert_own on public.memories with check (
  (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM (projects p
     JOIN project_members pm ON ((pm.project_id = p.id)))
  WHERE ((p.id = memories.project_id) AND (p.shared = true) AND (pm.user_id = ( SELECT auth.uid() AS uid)) AND (pm.role = ANY (ARRAY['owner'::text, 'editor'::text])))))))
  AND (agent_id IS NULL
       OR EXISTS (SELECT 1 FROM public.agents a WHERE a.id = memories.agent_id AND a.user_id = (select auth.uid()))
       OR EXISTS (SELECT 1 FROM public.agent_projects ap WHERE ap.agent_id = memories.agent_id
                    AND (public.member_role(ap.project_id, (select auth.uid())) = ANY (ARRAY['owner'::text, 'editor'::text])
                         OR EXISTS (SELECT 1 FROM public.projects pr WHERE pr.id = ap.project_id AND pr.user_id = (select auth.uid()))))));

alter policy users_update_own on public.memories with check (
  (((( SELECT auth.uid() AS uid) = user_id) OR (EXISTS ( SELECT 1
   FROM (projects p
     JOIN project_members pm ON ((pm.project_id = p.id)))
  WHERE ((p.id = memories.project_id) AND (p.shared = true) AND (pm.user_id = ( SELECT auth.uid() AS uid)) AND (pm.role = ANY (ARRAY['owner'::text, 'editor'::text])))))))
  AND (agent_id IS NULL
       OR EXISTS (SELECT 1 FROM public.agents a WHERE a.id = memories.agent_id AND a.user_id = (select auth.uid()))
       OR EXISTS (SELECT 1 FROM public.agent_projects ap WHERE ap.agent_id = memories.agent_id
                    AND (public.member_role(ap.project_id, (select auth.uid())) = ANY (ARRAY['owner'::text, 'editor'::text])
                         OR EXISTS (SELECT 1 FROM public.projects pr WHERE pr.id = ap.project_id AND pr.user_id = (select auth.uid()))))));

do $assert$
declare bad text; n int;
begin
  select string_agg(b.polname, ', ') into bad from sb581c_before b
    left join pg_policy p on p.polrelid = 'public.memories'::regclass and p.polname = b.polname
   where p.oid is null or p.polcmd is distinct from b.polcmd or p.polroles is distinct from b.polroles
      or p.polpermissive is distinct from b.polpermissive or pg_get_expr(p.polqual, p.polrelid) is distinct from b.q
      or (case when b.polname in ('users_insert_own', 'users_update_own')
               then strpos(pg_get_expr(p.polwithcheck, p.polrelid), left(b.w, strpos(b.w, ' AND ((agent_id IS NULL)'))) <> 1
                    or strpos(pg_get_expr(p.polwithcheck, p.polrelid), 'can_access_agent') > 0
                    or strpos(pg_get_expr(p.polwithcheck, p.polrelid), 'member_role(ap.project_id, ( SELECT auth.uid() AS uid))') = 0
               else pg_get_expr(p.polwithcheck, p.polrelid) is distinct from b.w end);
  if bad is not null or (select count(*) from pg_policy where polrelid = 'public.memories'::regclass) <> (select count(*) from sb581c_before) then
    raise exception 'SB-581c: unexpected policy change: %', coalesce(bad, 'policy count');
  end if;
  select count(*) into n from public.memories m join public.agents a on a.id = m.agent_id
   where a.user_id <> m.user_id
     and not exists (select 1 from public.agent_projects ap where ap.agent_id = m.agent_id
                      and (public.member_role(ap.project_id, m.user_id) in ('owner', 'editor')
                           or exists (select 1 from public.projects pr where pr.id = ap.project_id and pr.user_id = m.user_id)));
  if n > 0 then raise exception 'SB-581c: % existing agent memories break the new rule', n; end if;
end
$assert$;