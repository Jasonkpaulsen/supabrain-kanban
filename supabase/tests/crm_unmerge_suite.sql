-- CRM unmerge suite: TC-SB572-1..8 and -10 (ADR-CRM-006 §4.1). TC-SB572-9 is crm_search_suite.sql.
--
-- Runs as two signed-in users inside one transaction that always ends by raising, so every row
-- it creates is rolled back. Run as postgres. Pass = the raised message starts with
-- "CRM-UNMERGE PASS". "Unmerge" names and example.net addresses mark fixture data; none may
-- appear in an undo record.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; fails int;
  st text; st2 text; st3 text; st4 text;
  tFr uuid; gG uuid;
  pK uuid; pM uuid; pO uuid; pA uuid; pB uuid; pC uuid;
  cpMoved uuid;
  lg uuid; lg2 uuid; lg3 uuid; lg4 uuid; lg5 uuid;
  u jsonb; res jsonb;
  s0 jsonb; s1 jsonb;
begin
  -- snapshot of two people and every row that points at them (rolled back with the suite)
  create function pg_temp.um_snap(a uuid, b uuid) returns jsonb language sql stable as $s$
    select jsonb_object_agg(k, v) from (
      select 'p:' || x.id k, to_jsonb(x) - 'updated_at' - 'archived_at' - 'merged_at' v
        from public.crm_people x where x.id in (a, b)
      union all select 'cp:' || x.id, to_jsonb(x) - 'updated_at' - 'archived_at' from public.crm_contact_points x where x.person_id in (a, b)
      union all select 'rel:' || x.id, to_jsonb(x) - 'updated_at' - 'archived_at' from public.crm_person_relationships x
                 where x.person_id in (a, b) or x.related_person_id in (a, b)
      union all select 'fact:' || x.id, to_jsonb(x) - 'updated_at' - 'archived_at' from public.crm_facts x where x.person_id in (a, b)
      union all select 'gm:' || x.id, to_jsonb(x) - 'updated_at' - 'archived_at' from public.crm_group_members x where x.person_id in (a, b)
    ) z
  $s$;
  -- new functions get no PUBLIC execute here (SB-488 default privileges)
  grant execute on function pg_temp.um_snap(uuid, uuid) to authenticated;

  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into tFr from public.crm_relationship_types where user_id is null and code = 'friend';

  -- ------------------------------------------------------------------ seed the main pair
  insert into public.crm_people (display_name, given_name) values ('Unmergeka Keep', 'Unmergeka') returning id into pK;
  insert into public.crm_people (display_name, given_name, family_name, preferred_name)
    values ('Unmergemb Twin', 'Unmergemb', 'Twinfam', 'Umb') returning id into pM;
  insert into public.crm_people (display_name) values ('Unmergeoc Other') returning id into pO;
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pK, 'email', 'k.um@example.net', true);
  insert into public.crm_contact_points (person_id, kind, value) values (pK, 'email', 'shared.um@example.net');
  insert into public.crm_contact_points (person_id, kind, value) values (pK, 'email', 'shared2.um@example.net');
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pM, 'email', 'only.m@example.net', true);
  insert into public.crm_contact_points (person_id, kind, value) values (pM, 'email', 'shared.um@example.net');
  insert into public.crm_contact_points (person_id, kind, value) values (pM, 'phone', '+15550007777');
  insert into public.crm_contact_points (person_id, kind, value, archived) values (pM, 'email', 'shared2.um@example.net', true);
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pM, pO, tFr);
  insert into public.crm_facts (person_id, fact_type, value) values (pM, 'hobby', 'unmerge fixture fact');
  insert into public.crm_groups (name) values ('Unmerge Group') returning id into gG;
  insert into public.crm_group_members (group_id, person_id) values (gG, pM);

  s0 := pg_temp.um_snap(pK, pM);
  lg := public.crm_merge_people(pK, pM, 'duplicate_entry');
  select undo into u from public.crm_merge_log where id = lg;

  -- ------------------------------------------------------------------ TC-SB572-1: what a merge records
  r := r || jsonb_build_object('TC-SB572-1', case
         when jsonb_array_length(u->'moved'->'crm_contact_points.person_id') = 2
          and (select count(*) from jsonb_array_elements(u->'moved'->'crm_contact_points.person_id') x
                where (x->>'pref_reset')::boolean) = 1
          and jsonb_array_length(u->'kept'->'crm_contact_points') = 2
          and (select array_agg((x->>'was_archived')::boolean order by (x->>'was_archived')::boolean)
                 from jsonb_array_elements(u->'kept'->'crm_contact_points') x) = array[false, true]
          and u->'filled' @> '["family_name","preferred_name"]' and not (u->'filled' @> '["given_name"]')
          and (u->'moved' ? 'crm_person_relationships.person_id' or u->'moved' ? 'crm_person_relationships.related_person_id')
          and u->'moved' ? 'crm_facts.person_id' and u->'moved' ? 'crm_group_members.person_id'
          and (select bool_and(x->>'fp' ~ '^[0-9a-f]{32}$') from jsonb_each(u->'moved') e(k, v), jsonb_array_elements(e.v) x)
          and (select bool_and(x->>'fp' ~ '^[0-9a-f]{32}$') from jsonb_each(u->'kept') e(k, v), jsonb_array_elements(e.v) x)
          and u::text !~* '(example\.net|unmerge|twinfam)'
         then 'pass' else format('FAIL: %s', u) end);

  -- ------------------------------------------------------------------ TC-SB572-2: exact round trip
  res := public.crm_unmerge(lg, 'wrong_merge');
  s1 := pg_temp.um_snap(pK, pM);
  r := r || jsonb_build_object('TC-SB572-2', case
         when s0 = s1 and (res->>'rows_moved_back')::int = 5 and (res->>'rows_unarchived')::int = 1
          and (res->>'fields_cleared')::int = 2
         then 'pass'
         else format('FAIL: result %s; differing keys %s', res,
                (select jsonb_agg(k) from (select key k from jsonb_each(s0) except
                                           select key from jsonb_each(s1) e where s0->e.key = e.value) d)) end);

  -- ------------------------------------------------------------------ TC-SB572-6: recorded, not proposed again
  r := r || jsonb_build_object('TC-SB572-6', case
         when (select count(*) from public.crm_unmerges x where x.merge_log_id = lg and x.reason_code = 'wrong_merge') = 1
          and exists (select 1 from public.crm_duplicate_dismissals d where d.reason_code = 'unmerged'
                       and d.person_a = least(pK, pM) and d.person_b = greatest(pK, pM))
          and not exists (select 1 from public.crm_duplicate_candidates(200) c
                           where least(c.person_a, c.person_b) = least(pK, pM) and greatest(c.person_a, c.person_b) = greatest(pK, pM))
          and exists (select 1 from public.crm_audit_log a where a.action = 'unarchive' and a.entity_type = 'crm_people' and a.entity_id = pM)
         then 'pass' else 'FAIL: record, dismissal, candidates or audit' end);

  -- ------------------------------------------------------------------ TC-SB572-5a: no second undo
  st := null;
  begin perform public.crm_unmerge(lg, 'wrong_merge');
  exception when others then st := sqlstate; end;

  -- ------------------------------------------------------------------ TC-SB572-8: later rows stay on the kept person
  insert into public.crm_people (display_name) values ('Unmergeaa Keep') returning id into pA;
  insert into public.crm_people (display_name) values ('Unmergebb Twin') returning id into pB;
  insert into public.crm_contact_points (person_id, kind, value) values (pB, 'email', 'bb.um@example.net');
  lg2 := public.crm_merge_people(pA, pB, 'duplicate_entry');
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'email', 'after.um@example.net');
  perform public.crm_unmerge(lg2, 'wrong_merge');
  r := r || jsonb_build_object('TC-SB572-8', case
         when exists (select 1 from public.crm_contact_points c where c.person_id = pA and c.value = 'after.um@example.net')
          and exists (select 1 from public.crm_contact_points c where c.person_id = pB and c.value = 'bb.um@example.net')
          and (select not archived and merged_into_id is null from public.crm_people where id = pB)
         then 'pass' else 'FAIL' end);

  -- ------------------------------------------------------------------ TC-SB572-3: a moved row changed
  insert into public.crm_people (display_name) values ('Unmergecc Keep') returning id into pA;
  insert into public.crm_people (display_name) values ('Unmergedd Twin') returning id into pB;
  insert into public.crm_contact_points (person_id, kind, value) values (pB, 'email', 'dd.um@example.net') returning id into cpMoved;
  lg3 := public.crm_merge_people(pA, pB, 'duplicate_entry');
  update public.crm_contact_points set label = 'edited' where id = cpMoved;
  st2 := null;
  begin perform public.crm_unmerge(lg3, 'wrong_merge');
  exception when others then st2 := sqlstate; end;
  r := r || jsonb_build_object('TC-SB572-3', case
         when st2 = '55000'
          and (select archived and merged_into_id = pA from public.crm_people where id = pB)
          and (select person_id = pA from public.crm_contact_points where id = cpMoved)
          and not exists (select 1 from public.crm_unmerges x where x.merge_log_id = lg3)
         then 'pass' else format('FAIL: sqlstate %s', st2) end);

  -- ------------------------------------------------------------------ TC-SB572-4: a filled field was edited
  insert into public.crm_people (display_name, given_name) values ('Unmergeee Keep', 'Unmergeee') returning id into pA;
  insert into public.crm_people (display_name, family_name) values ('Unmergeff Twin', 'Fillfam') returning id into pB;
  lg4 := public.crm_merge_people(pA, pB, 'duplicate_entry');
  update public.crm_people set family_name = 'Editedfam' where id = pA;
  st3 := null;
  begin perform public.crm_unmerge(lg4, 'wrong_merge');
  exception when others then st3 := sqlstate; end;
  r := r || jsonb_build_object('TC-SB572-4', case
         when st3 = '55000' and (select archived from public.crm_people where id = pB)
          and (select family_name = 'Editedfam' from public.crm_people where id = pA)
         then 'pass' else format('FAIL: sqlstate %s', st3) end);

  -- ------------------------------------------------------------------ TC-SB572-5b: the kept person was merged since
  insert into public.crm_people (display_name) values ('Unmergegg Keep') returning id into pA;
  insert into public.crm_people (display_name) values ('Unmergehh Twin') returning id into pB;
  insert into public.crm_people (display_name) values ('Unmergeii Third') returning id into pC;
  lg5 := public.crm_merge_people(pA, pB, 'duplicate_entry');
  perform public.crm_merge_people(pC, pA, 'duplicate_entry');
  st4 := null;
  begin perform public.crm_unmerge(lg5, 'wrong_merge');
  exception when others then st4 := sqlstate; end;
  r := r || jsonb_build_object('TC-SB572-5', case when st = '55000' and st4 = '55000'
         then 'pass' else format('FAIL: second undo %s, chained %s', st, st4) end);

  -- ------------------------------------------------------------------ TC-SB572-7: owner-only and validated
  n := 0;
  begin perform public.crm_unmerge(lg3, 'bad reason');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform public.crm_unmerge(gen_random_uuid(), 'wrong_merge');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  begin perform public.crm_unmerge(lg3, 'wrong_merge');
  exception when others then if sqlstate in ('P0002', '42501') then n := n + 1; end if; end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  begin perform public.crm_unmerge(lg3, 'wrong_merge');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  r := r || jsonb_build_object('TC-SB572-7', case
         when n = 4 and (select archived from public.crm_people where id = (select merged_person_id from public.crm_merge_log where id = lg3))
         then 'pass' else format('FAIL: refused %s of 4', n) end);

  -- ------------------------------------------------------------------ TC-SB572-10: posture
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  n := 0;
  begin update public.crm_unmerges set reason_code = 'tampered' where true;
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  r := r || jsonb_build_object('TC-SB572-10', case
         when n = 1
          and not exists (select 1 from pg_proc where oid in ('public.crm_merge_people(uuid,uuid,text)'::regprocedure,
                                                            'public.crm_unmerge(uuid,text)'::regprocedure)
                           and (prosecdef or not proconfig @> array['search_path=""']))
          and not has_function_privilege('anon', 'public.crm_unmerge(uuid,text)', 'execute')
          and not has_function_privilege('anon', 'public.crm_merge_people(uuid,uuid,text)', 'execute')
          and (select relrowsecurity from pg_class where oid = 'public.crm_unmerges'::regclass)
          and not has_table_privilege('authenticated', 'public.crm_unmerges', 'update')
          and not has_table_privilege('anon', 'public.crm_unmerges', 'select')
          and not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                           where s.nspname = 'public' and p.proname not in ('crm_merge_people', 'crm_unmerge')
                             and p.prosrc ~* 'merged_into_id\s*=')
         then 'pass' else format('FAIL: update refused %s', n) end);

  select count(*) into fails from jsonb_each(r) where value <> '"pass"'::jsonb;
  if fails = 0 then
    raise exception 'CRM-UNMERGE PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-UNMERGE FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
