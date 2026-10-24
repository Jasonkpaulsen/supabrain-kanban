-- SB-581: a user who can use an agent can read that agent's memories (ADR-MEM-001).
--
-- Jason, SB-515 (2026-10-07): "Global memories should be available for all users that have
-- access. Using an agent should include the agent memory." users_select_own let a user read
-- global rows, their own rows, and project rows in a shared project they belong to; an
-- agent's memories written in another project were invisible to the agent's users.
--
-- 1. users_select_own gains one disjunct; its existing expression is kept verbatim as the
--    first part (asserted below against a snapshot). One permissive SELECT policy rather than
--    a companion keeps the advisor's multiple_permissive_policies lint from growing.
--      agent_id is not null and scope <> 'private'
--      and can_access_agent(agent_id, (select auth.uid()))
--    can_access_agent is SECURITY DEFINER and refuses to answer for anyone but the caller.
--    scope = 'private' stays owner-only, even with an agent_id. Cross-project exposure is the
--    intent: an agent's non-private memory is readable by every user of that agent, whatever
--    project it was written in. Measured before the change: 1 memory becomes newly readable
--    (a Family Care Manager memory, to the one other user who can access that agent).
-- 2. match_memories(p_agent) returns the agent's memories plus global ones in one call
--    (requirement 5). Signature, SECURITY INVOKER and search_path unchanged; RLS still decides.
-- The write policies, oauth_client_deny and the service role are unchanged.

create temp table sb581_before as
select polname, polcmd, polroles, polpermissive, pg_get_expr(polqual, polrelid) q, pg_get_expr(polwithcheck, polrelid) w
  from pg_policy where polrelid = 'public.memories'::regclass;

alter policy users_select_own on public.memories using (
  ((scope = 'global'::text) OR (user_id = ( SELECT auth.uid() AS uid)) OR ((scope = 'project'::text) AND (EXISTS ( SELECT 1
   FROM (projects p
     JOIN project_members pm ON ((pm.project_id = p.id)))
  WHERE ((p.id = memories.project_id) AND (p.shared = true) AND (pm.user_id = ( SELECT auth.uid() AS uid)))))))
  OR (agent_id IS NOT NULL AND scope <> 'private' AND public.can_access_agent(agent_id, (select auth.uid()))));

create or replace function public.match_memories(query_embedding extensions.vector, match_count integer default 10,
  p_project uuid default null, p_agent uuid default null, p_scope text[] default null, p_type text[] default null,
  p_min_importance text default null)
returns table(id uuid, type text, summary text, content text, importance text, scope text, agent_id uuid, project_id uuid, similarity double precision)
language sql
stable
set search_path to ''
as $function$
  SELECT m.id, m.type, m.summary, m.content, m.importance, m.scope, m.agent_id, m.project_id,
         1 - (m.embedding OPERATOR(extensions.<=>) query_embedding) AS similarity
  FROM public.memories m
  WHERE m.embedding IS NOT NULL
    AND m.archived = false
    AND (p_project IS NULL OR m.project_id = p_project)
    -- SB-581: recall for an agent is that agent's memories plus the global ones.
    AND (p_agent IS NULL OR m.agent_id = p_agent OR m.scope = 'global')
    AND (p_scope IS NULL OR m.scope = ANY(p_scope))
    AND (p_type IS NULL OR m.type = ANY(p_type))
    AND (p_min_importance IS NULL OR
         array_position(ARRAY['low','normal','high','critical'], m.importance)
         >= array_position(ARRAY['low','normal','high','critical'], p_min_importance))
  ORDER BY m.embedding OPERATOR(extensions.<=>) query_embedding
  LIMIT match_count;
$function$;

do $assert$
declare old text; new text; bad text;
begin
  select q into old from sb581_before where polname = 'users_select_own';
  select pg_get_expr(polqual, polrelid) into new from pg_policy where polrelid = 'public.memories'::regclass and polname = 'users_select_own';
  if strpos(new, substring(old from 2 for length(old) - 2)) <> 2 or strpos(new, 'can_access_agent(agent_id, ( SELECT auth.uid() AS uid))') = 0
     or strpos(new, '(scope <> ''private''::text)') = 0 then
    raise exception 'SB-581: users_select_own does not keep its old expression and add the agent path';
  end if;
  select string_agg(b.polname, ', ') into bad from sb581_before b
    left join pg_policy p on p.polrelid = 'public.memories'::regclass and p.polname = b.polname
   where p.oid is null or p.polcmd is distinct from b.polcmd or p.polroles is distinct from b.polroles
      or p.polpermissive is distinct from b.polpermissive or pg_get_expr(p.polwithcheck, p.polrelid) is distinct from b.w
      or (b.polname <> 'users_select_own' and pg_get_expr(p.polqual, p.polrelid) is distinct from b.q);
  if bad is not null or (select count(*) from pg_policy where polrelid = 'public.memories'::regclass) <> (select count(*) from sb581_before) then
    raise exception 'SB-581: another memories policy changed: %', coalesce(bad, 'policy count');
  end if;
  if (select prosecdef from pg_proc where oid = 'public.match_memories(extensions.vector,integer,uuid,uuid,text[],text[],text)'::regprocedure)
     or has_function_privilege('anon', 'public.match_memories(extensions.vector,integer,uuid,uuid,text[],text[],text)', 'execute')
     or strpos(pg_get_functiondef('public.match_memories(extensions.vector,integer,uuid,uuid,text[],text[],text)'::regprocedure),
               'm.agent_id = p_agent OR m.scope = ''global''') = 0 then
    raise exception 'SB-581: match_memories posture or agent filter wrong';
  end if;
end
$assert$;