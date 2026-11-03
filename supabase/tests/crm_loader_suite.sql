-- CRM internal loader suite: TC-SB577-1..11 (ADR-CRM-006 §2, §3, §6, §7).
--
-- Seeds source rows for user A as postgres, then runs the loaders as signed-in users inside one
-- transaction that always ends by raising, so every row it creates is rolled back.
-- Run as postgres. Pass = the raised message starts with "CRM-LOADER PASS".
-- ZXQ marks fixture data. ZXQSPECIALTY and ZXQNOTES must never reach the CRM.
-- User B's part runs B's real source rows and reports counts only, never values.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; fails int;
  pK uuid; pL uuid; pC uuid; uC uuid;
  res_h jsonb; res_i jsonb; res_b jsonb;
  vOwner uuid; vKidA uuid; vKidB uuid; vTeach uuid; vCo uuid; vDoc uuid; vNeighbor uuid;
  snap1 jsonb; snap2 jsonb;
  b_records jsonb;
begin
  -- ------------------------------------------------------------------ seed user A's sources (as postgres)
  insert into public.projects (name, domain, user_id) values ('Zxqkid Alpha Testfam', 'family', ua) returning id into pK;
  insert into public.projects (name, domain, user_id) values ('Zxqkid Beta Testfam', 'family', ua) returning id into pL;
  insert into public.projects (name, domain, user_id) values ('Zxq Towers LLC — Condo Operations', 'property', ua) returning id into pC;
  insert into public.condo_units (user_id, project_id, unit, monthly_maintenance) values (ua, pC, 'ZXQ-1', 0) returning id into uC;
  insert into public.condo_contacts (user_id, project_id, unit_id, role, first_name, last_name, relationship)
    values (ua, pC, uC, 'owner', 'Zxqowner', 'Testfam', 'Board President');
  insert into public.condo_contacts (user_id, project_id, unit_id, role, first_name, last_name, email, notes)
    values (ua, pC, uC, 'tenant', 'Zxqcondo', 'Neighbor', 'zxq.neighbor@example.net', 'ZXQNOTES tenant');
  insert into public.condo_contacts (user_id, project_id, unit_id, role, first_name, last_name)
    values (ua, pC, uC, 'co-owner', 'Zxqcoown', 'Person');
  insert into public.school_courses (user_id, child_project_id, child_name, course_name, school,
                                     teacher_of_record, teacher_email, co_teacher, notes)
    values (ua, pK, 'zxqkid', 'ZXQ Algebra', 'Zxq High', 'Ms Zxqteach', 'zxq.teach@example.net', 'Mr Zxqco', 'ZXQNOTES course');
  insert into public.school_courses (user_id, child_project_id, child_name, course_name, school, teacher_of_record, teacher_email)
    values (ua, pK, 'zxqkid', 'ZXQ Geometry', 'Zxq High', 'Ms Zxqteach', 'ZXQ.Teach@example.net');
  insert into public.school_courses (user_id, child_project_id, child_name, course_name, school, teacher_of_record)
    values (ua, pL, 'zxqkid', 'ZXQ Biology', 'Zxq High', 'Ms  Zxqteach');
  insert into public.health_providers (user_id, child_project_id, name, organization, email, specialty, notes)
    values (ua, pK, 'Dr Zxqdoc Care', 'Zxq Clinic', 'zxq.doc@example.net', 'ZXQSPECIALTY', 'ZXQNOTES provider');

  -- ------------------------------------------------------------------ TC-SB577-1: household
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  res_h := public.crm_load_household('{"given_name":"Zxqowner","family_name":"Testfam"}', 'initial_load');
  vOwner := public.crm_external_person('manual_json', 'household:owner');
  vKidA := public.crm_external_person('manual_json', 'household:child:' || pK);
  vKidB := public.crm_external_person('manual_json', 'household:child:' || pL);
  select count(*) into n from public.crm_people p
   where p.source_ref = 'manual_json:household' and p.confirmed_at is not null
     and p.meta->>'confirmed_by' = 'policy:tier_a';
  select count(*) into m from public.crm_person_relationships x
    join public.crm_relationship_types t on t.id = x.relationship_type_id
   where x.person_id = vOwner and t.code = 'parent' and x.related_person_id in (vKidA, vKidB);
  select count(*) into k from public.crm_person_relationships x
   where x.source_ref = 'manual_json:household' and x.confirmed_at is not null;
  r := r || jsonb_build_object('TC-SB577-1', case
         when vOwner is not null and vKidA is not null and vKidB is not null and n = 3
          and (select given_name || '|' || middle_name || '|' || family_name from public.crm_people where id = vKidA) = 'Zxqkid|Alpha|Testfam'
          and m = 2 and k = 3
          and (select count(*) from public.crm_person_relationships x join public.crm_relationship_types t on t.id = x.relationship_type_id
                where t.code = 'sibling' and least(x.person_id, x.related_person_id) = least(vKidA, vKidB)
                  and greatest(x.person_id, x.related_person_id) = greatest(vKidA, vKidB)) = 1
          and (select count(*) from public.crm_group_members gm join public.crm_groups g on g.id = gm.group_id
                where g.name = 'Household' and gm.person_id in (vOwner, vKidA, vKidB)) = 3
          and (select count(*) from public.crm_steward_decisions d where d.decision = 'auto_confirm' and d.rule = 'tier_a') = 6
          and (res_h->'import'->>'rejected')::int = 0
         then 'pass' else format('FAIL: %s confirmed %s parent %s rels %s', res_h, n, m, k) end);

  -- ------------------------------------------------------------------ TC-SB577-2: internal sources, Tier B
  select count(*) into n from public.crm_audit_log a where a.action = 'bulk_import';
  res_i := public.crm_load_internal_sources('initial_load');
  select count(*) into m from public.crm_audit_log a where a.action = 'bulk_import';
  r := r || jsonb_build_object('TC-SB577-2', case
         when m = n + 3
          and (select count(*) from public.crm_import_batches b where b.source = 'manual_json'
                and b.source_label in ('openbrain.condo_contacts','openbrain.school_courses','openbrain.health_providers')) = 3
          and (select count(*) from public.crm_import_batches b where b.source_label = 'openbrain.employer_details') = 0
          and (select count(*) from public.crm_people p where p.source_ref like 'manual_json:openbrain.%'
                and p.source_type = 'import' and p.confirmed_at is null) = 5
          and (select count(*) from public.crm_organizations o where o.name in ('Zxq Towers LLC','Zxq High','Zxq Clinic')) = 3
          and (select count(*) from public.crm_group_members gm join public.crm_groups g on g.id = gm.group_id where g.name = 'Condo') = 3
          and (select count(*) from public.crm_group_members gm join public.crm_groups g on g.id = gm.group_id where g.name = 'School') = 2
          and (select count(*) from public.crm_group_members gm join public.crm_groups g on g.id = gm.group_id where g.name = 'Care') = 1
          and (select sum(coalesce((v->'import'->>'rejected')::int, 0)) from jsonb_each(res_i) e(key, v)) = 0
         then 'pass' else format('FAIL: audit %s->%s result %s', n, m, res_i) end);

  -- ------------------------------------------------------------------ TC-SB577-3: self-match
  r := r || jsonb_build_object('TC-SB577-3', case
         when (select count(*) from public.crm_people p where p.name_normalized = 'zxqowner testfam' and not p.archived) = 1
          and exists (select 1 from public.crm_affiliations a join public.crm_organizations o on o.id = a.organization_id
                       where a.person_id = vOwner and o.name = 'Zxq Towers LLC' and a.role_title = 'Board President')
          and exists (select 1 from public.crm_group_members gm join public.crm_groups g on g.id = gm.group_id
                       where g.name = 'Condo' and gm.person_id = vOwner)
          and (res_i->'condo_contacts'->>'self_matched')::int = 1
         then 'pass' else format('FAIL: %s', res_i->'condo_contacts') end);

  -- ------------------------------------------------------------------ TC-SB577-7: teachers
  select p.id into vTeach from public.crm_people p where p.name_normalized = 'ms zxqteach';
  select p.id into vCo from public.crm_people p where p.name_normalized = 'mr zxqco';
  r := r || jsonb_build_object('TC-SB577-7', case
         when (select count(*) from public.crm_people p where p.name_normalized in ('ms zxqteach', 'ms  zxqteach')) = 1
          and exists (select 1 from public.crm_contact_points c where c.person_id = vTeach and c.value_normalized = 'zxq.teach@example.net')
          and exists (select 1 from public.crm_affiliations a where a.person_id = vTeach and a.role_title = 'Teacher')
          and exists (select 1 from public.crm_affiliations a where a.person_id = vCo and a.role_title = 'Co-teacher')
          and (select count(*) from public.crm_person_relationships x join public.crm_relationship_types t on t.id = x.relationship_type_id
                where t.code = 'teacher' and x.person_id = vTeach and x.related_person_id in (vKidA, vKidB)) = 2
          and (select count(*) from public.crm_person_relationships x join public.crm_relationship_types t on t.id = x.relationship_type_id
                where t.code = 'teacher' and x.person_id = vCo and x.related_person_id = vKidA) = 1
         then 'pass' else format('FAIL: school %s', res_i->'school_courses') end);

  -- ------------------------------------------------------------------ TC-SB577-5: health minimum
  select p.id into vDoc from public.crm_people p where p.name_normalized = 'dr zxqdoc care';
  select count(*) into n from (
    select to_jsonb(x)::text t from public.crm_people x union all
    select to_jsonb(x)::text from public.crm_facts x union all
    select to_jsonb(x)::text from public.crm_affiliations x union all
    select to_jsonb(x)::text from public.crm_organizations x union all
    select to_jsonb(x)::text from public.crm_contact_points x union all
    select to_jsonb(x)::text from public.crm_person_relationships x union all
    select to_jsonb(x)::text from public.crm_groups x) z
   where z.t ~ '(ZXQSPECIALTY|ZXQNOTES)';
  r := r || jsonb_build_object('TC-SB577-5', case
         when vDoc is not null and n = 0
          and (select count(*) from public.crm_affiliations a where a.person_id = vDoc and a.role_title is null) = 1
          and (select count(*) from public.crm_facts f where f.person_id = vDoc) = 0
          and (select count(*) from public.crm_person_relationships x where vDoc in (x.person_id, x.related_person_id)) = 0
         then 'pass' else format('FAIL: leaked %s', n) end);

  -- ------------------------------------------------------------------ TC-SB577-4: re-run changes nothing
  snap1 := jsonb_build_object(
    'people', (select count(*) from public.crm_people), 'points', (select count(*) from public.crm_contact_points),
    'orgs', (select count(*) from public.crm_organizations), 'affs', (select count(*) from public.crm_affiliations),
    'groups', (select count(*) from public.crm_groups), 'members', (select count(*) from public.crm_group_members),
    'rels', (select count(*) from public.crm_person_relationships), 'decisions', (select count(*) from public.crm_steward_decisions),
    'xids', (select count(*) from public.crm_external_ids), 'conflicts', (select count(*) from public.crm_import_conflicts));
  perform public.crm_load_household('{"given_name":"Zxqowner","family_name":"Testfam"}', 'initial_load');
  perform public.crm_load_internal_sources('initial_load');
  snap2 := jsonb_build_object(
    'people', (select count(*) from public.crm_people), 'points', (select count(*) from public.crm_contact_points),
    'orgs', (select count(*) from public.crm_organizations), 'affs', (select count(*) from public.crm_affiliations),
    'groups', (select count(*) from public.crm_groups), 'members', (select count(*) from public.crm_group_members),
    'rels', (select count(*) from public.crm_person_relationships), 'decisions', (select count(*) from public.crm_steward_decisions),
    'xids', (select count(*) from public.crm_external_ids), 'conflicts', (select count(*) from public.crm_import_conflicts));
  r := r || jsonb_build_object('TC-SB577-4', case when snap1 = snap2 and (snap1->>'conflicts')::int = 0
         then 'pass' else format('FAIL: %s -> %s', snap1, snap2) end);

  -- ------------------------------------------------------------------ TC-SB577-8: decision log
  n := 0;
  begin update public.crm_steward_decisions set rule = 'tampered' where true;
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  -- The same trigger also covers row removal (checked on the trigger definition, not executed).
  if exists (select 1 from pg_trigger where tgrelid = 'public.crm_steward_decisions'::regclass
              and tgname = 'trg_crm_steward_decisions_append_only' and (tgtype & 8) <> 0) then
    n := n + 1;
  end if;
  select count(*) into m from public.crm_steward_decisions d where to_jsonb(d)::text ~* 'zxq|example\.net';
  r := r || jsonb_build_object('TC-SB577-8', case
         when n = 2 and m = 0 and (select count(*) from public.crm_steward_decisions) = 6
          and not has_table_privilege('anon', 'public.crm_steward_decisions', 'select')
         then 'pass' else format('FAIL: refused %s, content rows %s', n, m) end);

  -- ------------------------------------------------------------------ TC-SB577-10: policy refusals
  select p.id into vNeighbor from public.crm_people p where p.name_normalized = 'zxqcondo neighbor';
  n := 0;
  begin perform public.crm_policy_confirm_person(vNeighbor, 'tier_a');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform public.crm_policy_confirm_person(vOwner, 'tier_b_14d');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  begin perform public.crm_policy_confirm_person(vOwner, 'tier_a');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  begin perform public.crm_policy_confirm_person(vOwner, 'tier_a');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  r := r || jsonb_build_object('TC-SB577-10', case
         when n = 4 and (select confirmed_at is null from public.crm_people where id = vNeighbor)
         then 'pass' else format('FAIL: refused %s of 4', n) end);

  -- ------------------------------------------------------------------ TC-SB577-6: owner-only (user B, real rows, counts only)
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;
  b_records := jsonb_build_object(
    'condo', jsonb_array_length(public.crm_build_contacts_condo()->'records'),
    'school', jsonb_array_length(public.crm_build_contacts_school()->'records'),
    'health', jsonb_array_length(public.crm_build_contacts_health()->'records'),
    'employers', jsonb_array_length(public.crm_build_contacts_employers()->'records'));
  n := (select count(*) from jsonb_array_elements((public.crm_build_contacts_condo()->'records')
                                                   || (public.crm_build_contacts_school()->'records')
                                                   || (public.crm_build_contacts_health()->'records')) x
         where x::text ~* 'zxq');
  res_b := public.crm_load_internal_sources('initial_load');
  select count(*) into m from public.crm_people p where p.name_normalized ~ 'zxq';
  select count(*) into k from public.crm_people p;
  reset role;
  r := r || jsonb_build_object('TC-SB577-6', case
         when n = 0 and m = 0 and (b_records->>'employers')::int = 0
          and (select count(*) from public.employer_details e where e.user_id <> ub) > 0
          and (select count(*) from public.crm_people p where p.user_id = ua and p.name_normalized ~ 'zxq') > 0
         then 'pass' else format('FAIL: zxq in B builders %s, in B crm %s', n, m) end);
  r := r || jsonb_build_object('B-preview', jsonb_build_object('records', b_records, 'b_people', k,
         'rejected', (select sum(coalesce((v->'import'->>'rejected')::int, 0)) from jsonb_each(res_b) e(key, v)),
         'conflicts', (select sum(coalesce((v->'import'->>'conflicts')::int, 0)) from jsonb_each(res_b) e(key, v))));

  -- ------------------------------------------------------------------ TC-SB577-9 / -11: tiers, posture
  r := r || jsonb_build_object('TC-SB577-9', case
         when array[public.crm_source_tier('manual', null), public.crm_source_tier('import', 'apple_contacts:x'),
                    public.crm_source_tier('import', 'vcard'), public.crm_source_tier('import', 'manual_json:household'),
                    public.crm_source_tier('import', 'manual_json:openbrain.condo_contacts'),
                    public.crm_source_tier('import', 'google_calendar'), public.crm_source_tier('agent', 'x'),
                    public.crm_source_tier('import', 'manual_json:other')]
              = array['A','A','A','A','B','C','C','C']
         then 'pass' else 'FAIL' end);
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public'
     and p.proname in ('crm_source_tier','crm_policy_confirm_person','crm_household_children','crm_school_teachers',
                       'crm_build_contacts_household','crm_build_contacts_condo','crm_build_contacts_school',
                       'crm_build_contacts_health','crm_build_contacts_employers','crm_external_person',
                       'crm_loader_group','crm_loader_relationship','crm_load_household','crm_load_internal_sources')
     and not p.prosecdef and p.proconfig @> array['search_path=""']
     and not has_function_privilege('anon', p.oid, 'execute');
  r := r || jsonb_build_object('TC-SB577-11', case
         when n = 14 and (select relrowsecurity from pg_class where oid = 'public.crm_steward_decisions'::regclass)
          and not exists (select 1 from pg_constraint where conrelid = 'public.crm_steward_decisions'::regclass and contype = 'f')
         then 'pass' else format('FAIL: %s of 14 functions conform', n) end);

  select count(*) into fails from jsonb_each(r) where key like 'TC-%' and value <> '"pass"'::jsonb;
  if fails = 0 then
    raise exception 'CRM-LOADER PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x like 'TC-%'), r::text;
  else
    raise exception 'CRM-LOADER FAIL (% checks failing): %', fails, r::text;
  end if;
end $suite$;
