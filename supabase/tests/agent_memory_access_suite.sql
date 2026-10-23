-- Agent memory access suite: TC-SB581-01 .. TC-SB581-04 (SB-581, ADR-MEM-001).
--
-- Run as postgres. One transaction that always ends by raising, so the fixture projects,
-- agents, memberships and memories (and the pg_net requests their inserts queue) do not
-- survive. Pass = the raised message starts with "AGENT_MEMORY_ACCESS PASS". The message
-- carries only check names, counts and fixture ids, no memory content.
--
-- Fixture, all written by the owner O:
--   P  shared project, U is a viewer.     Q  unshared project, U is not a member.
--   A  agent linked to P (so U can use A).  B  agent linked to Q only. Both paused (no prompt).
--   mA   A's project memory, written in Q     -> U reads it through the agent path only
--   mAp  A's private memory, written in Q     -> owner-only
--   mB   B's project memory, written in Q     -> hidden from U
--   mG   global memory                        -> everyone, as before
-- S is a stranger with no membership anywhere.

do $suite$
declare
  r jsonb := '{}'::jsonb; n int; fails int; st text; bad text; ids uuid[];
  o constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  u constant uuid := '0dd94a9f-1890-48b0-9e4f-a4bbfff949f0';
  s constant uuid := gen_random_uuid();
  p uuid; q uuid; a uuid; b uuid; ma uuid; map uuid; mb uuid; mg uuid;
  emb extensions.vector := ('[' || array_to_string(array_fill(0.01::float8, array[1536]), ',') || ']')::extensions.vector;
  sel text; old_inner_md5 constant text := '0d293905300c3c0b5f0f012d71b1cd33';
begin
  insert into public.projects (name, domain, user_id, shared) values ('qa-sb581 P', 'operations', o, true) returning id into p;
  insert into public.projects (name, domain, user_id, shared) values ('qa-sb581 Q', 'operations', o, false) returning id into q;
  insert into public.project_members (project_id, user_id, role) values (p, u, 'viewer');
  insert into public.agents (user_id, name, status) values (o, 'qa-sb581 agent A', 'paused') returning id into a;
  insert into public.agents (user_id, name, status) values (o, 'qa-sb581 agent B', 'paused') returning id into b;
  insert into public.agent_projects (agent_id, project_id, user_id) values (a, p, o), (b, q, o);
  insert into public.memories (project_id, type, content, user_id, agent_id, scope, embedding)
    values (q, 'insight', 'qa-sb581 mA', o, a, 'project', emb) returning id into ma;
  insert into public.memories (project_id, type, content, user_id, agent_id, scope, embedding)
    values (q, 'insight', 'qa-sb581 mAp', o, a, 'private', emb) returning id into map;
  insert into public.memories (project_id, type, content, user_id, agent_id, scope, embedding)
    values (q, 'insight', 'qa-sb581 mB', o, b, 'project', emb) returning id into mb;
  insert into public.memories (project_id, type, content, user_id, scope, embedding)
    values (null, 'insight', 'qa-sb581 mG', o, 'global', emb) returning id into mg;

  -- TC-SB581-01: U reads A's non-private memory from Q; not the private one, not B's.
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(id order by content) into ids from public.memories where content like 'qa-sb581 %';
  reset role;
  r := r || jsonb_build_object('TC-SB581-01.user_of_agent',
         case when ids = array[ma, mg] then 'pass' else 'FAIL: saw ' || coalesce(array_length(ids, 1), 0) || ' fixture rows' end);
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(id) into ids from public.memories where content like 'qa-sb581 %';
  reset role;
  r := r || jsonb_build_object('TC-SB581-01.stranger',
         case when ids = array[mg] then 'pass' else 'FAIL: saw ' || coalesce(array_length(ids, 1), 0) || ' fixture rows' end);
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.memories where id in (ma, map, mb, mg);
  reset role;
  r := r || jsonb_build_object('TC-SB581-01.owner_sees_all', case when n = 4 then 'pass' else 'FAIL: ' || n || ' of 4' end);

  -- TC-SB581-02: the old expression is kept verbatim; write rules unchanged; U still cannot write.
  select pg_get_expr(polqual, polrelid) into sel from pg_policy where polrelid = 'public.memories'::regclass and polname = 'users_select_own';
  r := r || jsonb_build_object('TC-SB581-02.old_expression_kept',
         case when md5(substring(sel from 2 for strpos(sel, ' OR ((agent_id IS NOT NULL)') - 2)) = old_inner_md5
                   and sel like '% OR ((agent_id IS NOT NULL) AND (scope <> ''private''::text) AND can_access_agent(agent_id, ( SELECT auth.uid() AS uid))))'
              then 'pass' else 'FAIL: ' || left(sel, 80) end);
  select string_agg(polname, ', ') into bad from (values
      ('Service role full access', 'fe2e7aa3a94b94b876d7713f1517686d'), ('oauth_client_deny', '35c27e4104835e0eb15f1858a47ebab9'),
      ('users_delete_own', 'a1fc7aa105a1b503f03297d4c928519f'), ('users_insert_own', '14588e98850852aae627a1e73165f848'),
      ('users_update_own', '9d3e163a61034737f1503c0e69a944d7')) v(polname, h)
   where not exists (select 1 from pg_policy pp where pp.polrelid = 'public.memories'::regclass and pp.polname = v.polname
                       and md5(coalesce(pg_get_expr(pp.polqual, pp.polrelid), '') || '|' || coalesce(pg_get_expr(pp.polwithcheck, pp.polrelid), '')) = v.h);
  r := r || jsonb_build_object('TC-SB581-02.write_policies_unchanged',
         case when bad is null and (select count(*) from pg_policy where polrelid = 'public.memories'::regclass) = 6 then 'pass' else 'FAIL: ' || coalesce(bad, 'policy count') end);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  update public.memories set content = 'qa-sb581 changed' where id = ma;
  get diagnostics n = row_count;
  begin
    insert into public.memories (project_id, type, content, user_id, agent_id, scope) values (q, 'insight', 'qa-sb581 forged', o, a, 'project');
    st := 'inserted';
  exception when others then st := sqlstate;
  end;
  reset role;
  r := r || jsonb_build_object('TC-SB581-02.user_of_agent_cannot_write',
         case when n = 0 and st = '42501' then 'pass' else 'FAIL: updated ' || n || ', insert ' || st end);

  -- TC-SB581-03: match_memories(p_agent => A) as U is A's readable rows plus global ones.
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(m.id order by m.id), count(*) filter (where m.agent_id is distinct from a and m.scope <> 'global')
    into ids, n from public.match_memories(emb, 200, p_agent => a) m;
  reset role;
  r := r || jsonb_build_object('TC-SB581-03.agent_plus_global',
         case when ma = any(ids) and mg = any(ids) and not map = any(ids) and not mb = any(ids) and n = 0
              then 'pass' else 'FAIL: ' || coalesce(array_length(ids, 1), 0) || ' rows, ' || n || ' foreign' end);
  r := r || jsonb_build_object('TC-SB581-03.posture',
         case when (select not prosecdef and proconfig = array['search_path=""'] from pg_proc
                     where oid = 'public.match_memories(extensions.vector,integer,uuid,uuid,text[],text[],text)'::regprocedure)
                   and not has_function_privilege('anon', 'public.match_memories(extensions.vector,integer,uuid,uuid,text[],text[],text)', 'execute')
              then 'pass' else 'FAIL' end);

  -- TC-SB581-04: over the real rows, every row the agent path adds is non-private, carries an
  -- agent the user can use, and is not readable by the old rule. Measured at review: 1.
  select count(*), count(*) filter (where mm.scope = 'private' or mm.agent_id is null) into n, fails
    from public.memories mm cross join (select id from auth.users) usr
   where mm.content not like 'qa-sb581 %'
     and mm.agent_id is not null and mm.scope <> 'private' and public.can_access_agent(mm.agent_id, usr.id)
     and not (mm.scope = 'global' or mm.user_id = usr.id
              or (mm.scope = 'project' and exists (select 1 from public.projects pr join public.project_members pm on pm.project_id = pr.id
                                                   where pr.id = mm.project_id and pr.shared and pm.user_id = usr.id)));
  r := r || jsonb_build_object('TC-SB581-04.delta_shape', case when fails = 0 then 'pass' else 'FAIL: ' || fails || ' private or agentless' end);
  r := r || jsonb_build_object('TC-SB581-04.evidence', format('newly readable (user, memory) pairs: %s (1 at review, 2026-10-23)', n));

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'AGENT_MEMORY_ACCESS PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  else
    raise exception 'AGENT_MEMORY_ACCESS FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  end if;
end $suite$;
