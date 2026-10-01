-- CRM QA suite: TC-SB453..456, TC-SB462..465 (ADR-CRM-001).
--
-- Runs as two signed-in users (A and B) by switching role and JWT claims inside
-- one transaction, and ALWAYS ends by raising: the report is the error text,
-- and every row written here is rolled back. Nothing persists. Only invented
-- names and example.com addresses are used.
--
-- Run it as postgres (the Supabase SQL editor or the MCP execute_sql tool).
-- Pass = each raised message starts with "CRM-SUITE ... PASS".
--
-- Two blocks. Part 2 holds every DELETE, because the MCP connector holds any
-- statement containing DELETE for human confirmation. Keeping the deletes apart
-- lets part 1 run unattended. Part 2 is equally rolled back; it just has to be
-- confirmed. Run each block as its own call.

-- ============================================================ PART 1
do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';   -- QA fixture user
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- second real user (rolled back)
  r jsonb := '{}'::jsonb;
  st text;
  n int; m int;
  b boolean;
  t text;
  pA uuid; pA2 uuid; pA3 uuid; pLone uuid; pB1 uuid; pB2 uuid;
  cp1 uuid; cpAgent uuid;
  tParent uuid; tFriend uuid; tColleague uuid; tSibling uuid; tCustomA uuid;
  o1 uuid; o2 uuid; g1 uuid; g2 uuid; tag1 uuid;
  f1 uuid; f3 uuid;
  d date;
  owned text[] := array['crm_people','crm_contact_points','crm_addresses','crm_person_relationships',
                        'crm_organizations','crm_affiliations','crm_groups','crm_group_members',
                        'crm_tags','crm_entity_tags','crm_important_dates','crm_facts'];
  fails int;
begin
  -- =============================================================== as user A
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- TC-SB453-V1: a person needs only a display name; owner is defaulted
  insert into public.crm_people (display_name) values ('Avery Testperson') returning id into pA;
  select user_id = ua into b from public.crm_people where id = pA;
  r := r || jsonb_build_object('TC-SB453-V1.owner_defaulted', case when b then 'pass' else 'FAIL' end);
  begin
    insert into public.crm_people (display_name) values ('   ');
    r := r || jsonb_build_object('TC-SB453-V1.blank_rejected', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB453-V1.blank_rejected', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_people (display_name) values ('Blake Testperson') returning id into pA2;
  insert into public.crm_people (display_name) values ('Casey Testperson') returning id into pA3;
  insert into public.crm_people (display_name) values ('Lone Testperson') returning id into pLone;

  -- TC-SB453-V2: many contact points and addresses, normalized duplicates refused
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pA, 'email', 'pat@example.com', true) returning id into cp1;
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'email', 'avery.alt@example.com');
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'phone', '+1 (555) 010-0000');
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'phone', '+1 555 010 0001');
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'handle', '@avery_test');
  insert into public.crm_addresses (person_id, label, line1, city, country_code, is_preferred) values (pA, 'home', '1 Example St', 'Exampleton', 'US', true);
  insert into public.crm_addresses (person_id, label, city, country_code) values (pA, 'work', 'Sampleville', 'US');
  select count(*) into n from public.crm_contact_points where person_id = pA;
  select count(*) into m from public.crm_addresses where person_id = pA;
  r := r || jsonb_build_object('TC-SB453-V2.multiple', case when n = 5 and m = 2 then 'pass' else format('FAIL: %s cps, %s addrs', n, m) end);
  begin
    insert into public.crm_contact_points (person_id, kind, value) values (pA, 'email', ' Pat@Example.COM ');
    r := r || jsonb_build_object('TC-SB453-V2.email_dup', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB453-V2.email_dup', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_contact_points (person_id, kind, value) values (pA, 'phone', '+15550100000');
    r := r || jsonb_build_object('TC-SB453-V2.phone_dup', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB453-V2.phone_dup', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB453-V3: history retained; one preferred current value per kind
  update public.crm_contact_points set is_current = false, is_preferred = false, valid_until = date '2026-09-30' where id = cp1;
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pA, 'email', 'avery.new@example.com', true);
  select count(*) into n from public.crm_contact_points where id = cp1 and not is_current;
  r := r || jsonb_build_object('TC-SB453-V3.old_retained', case when n = 1 then 'pass' else 'FAIL' end);
  begin
    insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pA, 'email', 'avery.third@example.com', true);
    r := r || jsonb_build_object('TC-SB453-V3.second_preferred', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB453-V3.second_preferred', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB454: relationships
  select id into tParent    from public.crm_relationship_types where user_id is null and code = 'parent';
  select id into tFriend    from public.crm_relationship_types where user_id is null and code = 'friend';
  select id into tColleague from public.crm_relationship_types where user_id is null and code = 'colleague';
  select id into tSibling   from public.crm_relationship_types where user_id is null and code = 'sibling';

  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pA, pA3, tFriend);
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pA, pA3, tColleague);
  select count(*) into n from public.crm_relationships_expanded where person_id = pA and other_person_id = pA3;
  r := r || jsonb_build_object('TC-SB454-V1', case when n = 2 then 'pass' else format('FAIL: %s', n) end);

  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pA, pA2, tParent);
  select other_is into st from public.crm_relationships_expanded where person_id = pA2 and other_person_id = pA;
  r := r || jsonb_build_object('TC-SB454-V2.child_side', case when st = 'parent' then 'pass' else 'FAIL: ' || coalesce(st, 'null') end);
  select other_is into st from public.crm_relationships_expanded where person_id = pA and other_person_id = pA2;
  r := r || jsonb_build_object('TC-SB454-V2.parent_side', case when st = 'child' then 'pass' else 'FAIL: ' || coalesce(st, 'null') end);

  -- symmetric: inserted "backwards" on purpose, then the reverse must be a duplicate
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id)
    values (greatest(pA2, pA3), least(pA2, pA3), tSibling);
  select count(*) into n from public.crm_person_relationships
   where relationship_type_id = tSibling and person_id = least(pA2, pA3) and related_person_id = greatest(pA2, pA3);
  r := r || jsonb_build_object('TC-SB454-V3.canonical', case when n = 1 then 'pass' else 'FAIL' end);
  begin
    insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (least(pA2, pA3), greatest(pA2, pA3), tSibling);
    r := r || jsonb_build_object('TC-SB454-V3.reverse_dup', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB454-V3.reverse_dup', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_relationships_expanded where code = 'sibling' and other_is = 'sibling'
     and ((person_id = pA2 and other_person_id = pA3) or (person_id = pA3 and other_person_id = pA2));
  r := r || jsonb_build_object('TC-SB454-V3.both_sides', case when n = 2 then 'pass' else format('FAIL: %s', n) end);

  begin
    insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pA, pA, tFriend);
    r := r || jsonb_build_object('TC-SB454-V4.self', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB454-V4.self', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  update public.crm_relationship_types set label = 'hacked' where id = tParent;
  get diagnostics n = row_count;
  r := r || jsonb_build_object('TC-SB454-V4.global_readonly', case when n = 0 then 'pass' else 'FAIL: updated' end);
  begin
    insert into public.crm_relationship_types (user_id, code, label, is_symmetric) values (null, 'global_forge', 'forged', true);
    r := r || jsonb_build_object('TC-SB454-V4.no_global_insert', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB454-V4.no_global_insert', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_relationship_types (code, label, inverse_label, category) values ('godparent', 'godparent', 'godchild', 'family') returning id into tCustomA;

  -- TC-SB455: organizations and affiliations
  insert into public.crm_organizations (name, org_type) values ('Example Corp', 'company') returning id into o1;
  insert into public.crm_organizations (name, org_type) values ('Example School', 'school') returning id into o2;
  insert into public.crm_affiliations (person_id, organization_id, role_title, start_date) values (pA, o1, 'Engineer', date '2024-01-01');
  insert into public.crm_affiliations (person_id, organization_id, role_title, start_date, end_date) values (pA, o1, 'Intern', date '2019-06-01', date '2023-12-31');
  insert into public.crm_affiliations (person_id, organization_id, role_title, department) values (pA, o2, 'Board member', 'Governance');
  select count(*), count(*) filter (where is_current) into n, m from public.crm_affiliations where person_id = pA;
  r := r || jsonb_build_object('TC-SB455-V1.multiple', case when n = 3 and m = 2 then 'pass' else format('FAIL: %s/%s', n, m) end);
  begin
    insert into public.crm_affiliations (person_id, organization_id, start_date, end_date) values (pA, o2, date '2025-01-01', date '2024-01-01');
    r := r || jsonb_build_object('TC-SB455-V1.bad_range', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB455-V1.bad_range', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB456: groups, tags, dates
  insert into public.crm_groups (name) values ('Family') returning id into g1;
  insert into public.crm_groups (name) values ('Close Friends') returning id into g2;
  insert into public.crm_group_members (group_id, person_id) values (g1, pA), (g2, pA), (g1, pA2);
  select count(*) into n from public.crm_group_members where person_id = pA;
  select count(*) into m from public.crm_group_members where group_id = g1;
  r := r || jsonb_build_object('TC-SB456-V1.many_to_many', case when n = 2 and m = 2 then 'pass' else format('FAIL: %s/%s', n, m) end);
  begin
    insert into public.crm_group_members (group_id, person_id) values (g1, pA);
    r := r || jsonb_build_object('TC-SB456-V1.dup', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB456-V1.dup', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_tags (name) values ('vip') returning id into tag1;
  insert into public.crm_entity_tags (tag_id, person_id) values (tag1, pA);
  insert into public.crm_entity_tags (tag_id, organization_id) values (tag1, o1);
  select count(*) into n from public.crm_entity_tags where tag_id = tag1;
  r := r || jsonb_build_object('TC-SB456-V2.person_and_org', case when n = 2 then 'pass' else format('FAIL: %s', n) end);
  begin
    insert into public.crm_entity_tags (tag_id) values (tag1);
    r := r || jsonb_build_object('TC-SB456-V2.neither', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB456-V2.neither', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_entity_tags (tag_id, person_id, organization_id) values (tag1, pA2, o2);
    r := r || jsonb_build_object('TC-SB456-V2.both', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB456-V2.both', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_important_dates (person_id, kind, month, day) values (pA, 'birthday', 3, 14);
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pA, 'anniversary', 6, 1, 2015);
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pA2, 'birthday', 2, 29, 2012);
  select public.crm_next_occurrence(month, day, year, recurrence, date '2027-01-10') into d
    from public.crm_important_dates where person_id = pA2 and kind = 'birthday';
  r := r || jsonb_build_object('TC-SB456-V3.leap_day', case when d = date '2027-02-28' then 'pass' else 'FAIL: ' || coalesce(d::text, 'null') end);
  select public.crm_next_occurrence(month, day, year, recurrence, date '2026-10-01') into d
    from public.crm_important_dates where person_id = pA and kind = 'birthday';
  r := r || jsonb_build_object('TC-SB456-V3.no_year', case when d = date '2027-03-14' then 'pass' else 'FAIL: ' || coalesce(d::text, 'null') end);
  begin
    insert into public.crm_important_dates (person_id, kind, month, day) values (pA, 'other', 2, 30);
    r := r || jsonb_build_object('TC-SB456-V3.feb30', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB456-V3.feb30', case when sqlstate in ('22008', '23514') then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB463: provenance
  begin
    insert into public.crm_contact_points (person_id, kind, value, source_type) values (pA2, 'email', 'blake@example.com', 'agent');
    r := r || jsonb_build_object('TC-SB463-V1.no_confidence', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB463-V1.no_confidence', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_contact_points (person_id, kind, value, source_type, source_ref, confidence)
    values (pA2, 'email', 'blake@example.com', 'agent', 'qa_suite', 0.40) returning id into cpAgent;
  r := r || jsonb_build_object('TC-SB463-V1.with_confidence', 'pass');
  select is_confirmed into b from public.crm_contact_points where id = cpAgent;
  r := r || jsonb_build_object('TC-SB463-V2.unconfirmed', case when not b then 'pass' else 'FAIL' end);
  update public.crm_contact_points set confirmed_at = now() where id = cpAgent;
  select is_confirmed into b from public.crm_contact_points where id = cpAgent;
  r := r || jsonb_build_object('TC-SB463-V2.confirmed', case when b then 'pass' else 'FAIL' end);
  select is_confirmed into b from public.crm_contact_points where id = cp1;
  r := r || jsonb_build_object('TC-SB463-V2.manual', case when b then 'pass' else 'FAIL' end);

  -- archive pA3: references kept, stamp set, audited; then unarchive
  update public.crm_people set archived = true where id = pA3;
  select count(*) into n from public.crm_person_relationships where person_id = pA3 or related_person_id = pA3;
  select archived_at is not null into b from public.crm_people where id = pA3;
  r := r || jsonb_build_object('TC-SB463-V3.archive_keeps_refs', case when n = 3 and b then 'pass' else format('FAIL: %s refs, stamped=%s', n, b) end);
  update public.crm_people set archived = false where id = pA3;
  select archived_at is null into b from public.crm_people where id = pA3;
  r := r || jsonb_build_object('TC-SB463-V3.unarchive_clears', case when b then 'pass' else 'FAIL' end);

  -- TC-SB464: sensitivity and agent retrieval
  insert into public.crm_facts (person_id, fact_type, value) values (pA, 'coffee_order', 'oat flat white') returning id into f1;
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pA, 'home_wifi_name', 'example-net', 'private');
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pA, 'note', 'test-sensitive-value-xyz', 'sensitive') returning id into f3;
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pA, 'note', 'test-highly-sensitive-value-xyz', 'highly_sensitive');
  insert into public.crm_facts (person_id, fact_type, value) values (pA, 'note', 'diagnosed with an invented test condition');
  select sensitivity into st from public.crm_facts where person_id = pA and value like 'diagnosed%';
  r := r || jsonb_build_object('TC-SB464-V3.not_inferred', case when st = 'normal' then 'pass' else 'FAIL: ' || st end);

  select count(*), count(*) filter (where sensitivity in ('sensitive', 'highly_sensitive'))
    into n, m from public.crm_facts_for_agent(pA);
  r := r || jsonb_build_object('TC-SB464-V1', case when n = 3 and m = 0 then 'pass' else format('FAIL: %s rows, %s restricted', n, m) end);
  begin
    perform * from public.crm_facts_for_agent(pA, true);
    r := r || jsonb_build_object('TC-SB464-V2.no_reason', 'FAIL: returned');
  exception when others then
    r := r || jsonb_build_object('TC-SB464-V2.no_reason', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    perform * from public.crm_facts_for_agent(pA, true, 'Because I said so');
    r := r || jsonb_build_object('TC-SB464-V2.prose_reason', 'FAIL: returned');
  exception when others then
    r := r || jsonb_build_object('TC-SB464-V2.prose_reason', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_facts_for_agent(pA, true, 'qa_suite_review');
  select count(*) into m from public.crm_audit_log where action = 'restricted_read' and entity_id = pA and reason_code = 'qa_suite_review' and entity_count = 2;
  r := r || jsonb_build_object('TC-SB464-V2.with_reason', case when n = 5 and m = 1 then 'pass' else format('FAIL: %s rows, %s audit', n, m) end);

  -- TC-SB462-V1: sensitivity change, archive/unarchive (above), delete
  update public.crm_facts set sensitivity = 'private' where id = f1;
  select count(*) filter (where action = 'sensitivity_change' and entity_id = f1 and reason_code = 'normal_to_private'),
         count(*) filter (where action = 'archive'   and entity_id = pA3),
         count(*) filter (where action = 'unarchive' and entity_id = pA3)
    into n, m, fails from (select * from public.crm_audit_log where user_id = ua and actor_id = ua) a;
  r := r || jsonb_build_object('TC-SB462-V1.sensitivity_archive', case when n = 1 and m = 1 and fails = 1 then 'pass'
                                                else format('FAIL: sens=%s arch=%s unarch=%s', n, m, fails) end);
  select count(*) into n from public.crm_audit_log
   where user_id = ua and (actor_kind <> 'user' and action <> 'restricted_read');
  r := r || jsonb_build_object('TC-SB462-V1.actor_kind', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- TC-SB462-V2: append-only, as the owner
  begin
    update public.crm_audit_log set outcome = 'failed' where user_id = ua;
    r := r || jsonb_build_object('TC-SB462-V2.owner_update', 'FAIL: allowed');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V2.owner_update', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB465-V3: UPDATE cannot hand a row to another owner
  begin
    update public.crm_people set user_id = ub where id = pLone;
    r := r || jsonb_build_object('TC-SB465-V3', 'FAIL: reassigned');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V3', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- =============================================================== as user B
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);

  -- TC-SB465-V2: isolation on every owned table
  foreach t in array owned loop
    execute format('select count(*) from public.%I where user_id = %L', t, ua) into n;
    r := r || jsonb_build_object('TC-SB465-V2.select.' || t, case when n = 0 then 'pass' else format('FAIL: sees %s', n) end);
    execute format('update public.%I set meta = meta || ''{"x":1}'' where user_id = %L', t, ua);
    get diagnostics n = row_count;
    r := r || jsonb_build_object('TC-SB465-V2.update.' || t, case when n = 0 then 'pass' else format('FAIL: updated %s', n) end);
  end loop;
  select count(*) into n from public.crm_relationships_expanded where user_id = ua;
  r := r || jsonb_build_object('TC-SB465-V2.select.crm_relationships_expanded', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from public.crm_audit_log where user_id = ua;
  r := r || jsonb_build_object('TC-SB465-V2.select.crm_audit_log', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from public.crm_relationship_types where id = tCustomA;
  r := r || jsonb_build_object('TC-SB454-V4.custom_private', case when n = 0 then 'pass' else 'FAIL: visible' end);
  begin
    insert into public.crm_people (user_id, display_name) values (ua, 'Forged Testperson');
    r := r || jsonb_build_object('TC-SB465-V2.insert_as_other', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V2.insert_as_other', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB465-V5: a child row cannot point at A's parent, even knowing the UUID
  begin
    insert into public.crm_contact_points (person_id, kind, value) values (pA, 'email', 'intruder@example.com');
    r := r || jsonb_build_object('TC-SB465-V5.contact_point', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V5.contact_point', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_people (display_name) values ('Bea Testperson') returning id into pB1;
  insert into public.crm_people (display_name) values ('Bo Testperson') returning id into pB2;
  begin
    insert into public.crm_group_members (group_id, person_id) values (g1, pB1);
    r := r || jsonb_build_object('TC-SB465-V5.group_member', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V5.group_member', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_affiliations (person_id, organization_id) values (pB1, o1);
    r := r || jsonb_build_object('TC-SB465-V5.affiliation', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V5.affiliation', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pB1, pB2, tCustomA);
    r := r || jsonb_build_object('TC-SB454-V4.foreign_custom_type', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB454-V4.foreign_custom_type', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB464-V4: agent retrieval obeys RLS
  select count(*) into n from public.crm_facts_for_agent(pA);
  select count(*) into m from public.crm_facts_for_agent(pA, true, 'qa_suite_probe');
  r := r || jsonb_build_object('TC-SB464-V4', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s / %s', n, m) end);

  -- TC-SB462-V4: cannot forge audit rows for someone else
  begin
    insert into public.crm_audit_log (user_id, actor_id, action, entity_type) values (ua, ub, 'export', 'crm_people');
    r := r || jsonb_build_object('TC-SB462-V4.owner', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V4.owner', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_audit_log (user_id, actor_id, action, entity_type) values (ub, ua, 'export', 'crm_people');
    r := r || jsonb_build_object('TC-SB462-V4.actor', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V4.actor', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    perform public.crm_audit('export', 'crm_people', null, 1, 'succeeded', null, null, ua);
    r := r || jsonb_build_object('TC-SB462-V4.via_function', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V4.via_function', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- =============================================================== as postgres / service_role
  reset role;
  perform set_config('request.jwt.claims', '{}', true);

  begin
    update public.crm_audit_log set outcome = 'failed' where user_id = ua;
    r := r || jsonb_build_object('TC-SB462-V2.postgres_update', 'FAIL: allowed');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V2.postgres_update', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  set local role service_role;
  begin
    insert into public.crm_contact_points (user_id, person_id, kind, value) values (ub, pA, 'email', 'svc@example.com');
    r := r || jsonb_build_object('TC-SB465-V5.service_role', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB465-V5.service_role', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  reset role;

  -- TC-SB462-V3: no content reaches the audit log
  select count(*) into n from public.crm_audit_log a
   where a.user_id in (ua, ub)
     and to_jsonb(a)::text ~* '(testperson|example\.com|sensitive-value|flat white|example-net|diagnosed)';
  r := r || jsonb_build_object('TC-SB462-V3.no_content', case when n = 0 then 'pass' else format('FAIL: %s rows', n) end);

  -- TC-SB465-V1 / V4: catalog. Every CRM base table has RLS and owner policies
  -- (types and audit have their own, checked separately); anon has nothing.
  foreach t in array owned loop
    begin
      perform public.crm_assert_owned_table(('public.' || t)::regclass);
      r := r || jsonb_build_object('TC-SB465-V1.' || t, 'pass');
    exception when others then
      r := r || jsonb_build_object('TC-SB465-V1.' || t, 'FAIL: ' || sqlerrm);
    end;
  end loop;
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname like 'crm\_%' and c.relkind in ('r', 'v')
     and exists (select 1 from aclexplode(c.relacl) a
                  where a.grantee in (0, 'anon'::regrole::oid));   -- any privilege to anon or PUBLIC
  select count(*) into m from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and has_function_privilege('anon', p.oid, 'execute');
  r := r || jsonb_build_object('TC-SB465-V4.anon', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s relations, %s functions', n, m) end);
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname like 'crm\_%' and c.relkind = 'r' and not c.relrowsecurity;
  r := r || jsonb_build_object('TC-SB465-V1.all_tables_rls', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- TC-SB453-V4: lookup indexes, and every FK has an index leading with its columns
  select count(*) into n from pg_indexes where indexname in ('crm_contact_points_lookup', 'crm_people_user_name');
  r := r || jsonb_build_object('TC-SB453-V4.lookup', case when n = 2 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                       and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  r := r || jsonb_build_object('TC-SB453-V4.fk_indexed', case when n = 0 then 'pass' else format('FAIL: %s unindexed FKs', n) end);

  -- TC-SB455-V2 / V3
  select count(*) into n from pg_indexes where indexname in ('crm_affiliations_current_by_person', 'crm_affiliations_current_by_org');
  r := r || jsonb_build_object('TC-SB455-V2', case when n = 2 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'crm_people' and column_name ~ '(org|employer|company|title|department)';
  r := r || jsonb_build_object('TC-SB455-V3', case when n = 0 then 'pass' else 'FAIL' end);

  -- TC-SB464-V3: nothing assigns sensitivity
  select count(*) into n from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid = 'public.crm_facts'::regclass and not t.tgisinternal and p.prosrc ~* 'new\.sensitivity\s*:=';
  r := r || jsonb_build_object('TC-SB464-V3.no_trigger', case when n = 0 then 'pass' else 'FAIL' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-SUITE PART 1 PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-SUITE PART 1 FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;

-- ============================================================ PART 2 (deletes)
do $suite2$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; fails int;
  t text;
  pA uuid; pB uuid; pDel uuid; o1 uuid; g1 uuid; tag1 uuid;
  owned text[] := array['crm_people','crm_contact_points','crm_addresses','crm_person_relationships',
                        'crm_organizations','crm_affiliations','crm_groups','crm_group_members',
                        'crm_tags','crm_entity_tags','crm_important_dates','crm_facts'];
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- one row of A's in every owned table
  insert into public.crm_people (display_name) values ('Avery Testperson') returning id into pA;
  insert into public.crm_people (display_name) values ('Blake Testperson') returning id into pB;
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'email', 'pat@example.com');
  insert into public.crm_addresses (person_id, city) values (pA, 'Exampleton');
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id)
    select pA, pB, id from public.crm_relationship_types where user_id is null and code = 'friend';
  insert into public.crm_organizations (name) values ('Example Corp') returning id into o1;
  insert into public.crm_affiliations (person_id, organization_id) values (pA, o1);
  insert into public.crm_groups (name) values ('Family') returning id into g1;
  insert into public.crm_group_members (group_id, person_id) values (g1, pA);
  insert into public.crm_tags (name) values ('vip') returning id into tag1;
  insert into public.crm_entity_tags (tag_id, person_id) values (tag1, pA);
  insert into public.crm_important_dates (person_id, kind, month, day) values (pA, 'birthday', 3, 14);
  insert into public.crm_facts (person_id, fact_type, value) values (pA, 'coffee_order', 'oat flat white');

  -- TC-SB462-V1 (delete half): a cascading delete audits every row it removes
  insert into public.crm_people (display_name) values ('Dana Testperson') returning id into pDel;
  insert into public.crm_contact_points (person_id, kind, value) values (pDel, 'email', 'dana@example.com');
  delete from public.crm_people where id = pDel;
  select count(*) filter (where entity_type = 'crm_people' and entity_id = pDel),
         count(*) filter (where entity_type = 'crm_contact_points')
    into n, m from public.crm_audit_log where user_id = ua and actor_id = ua and action = 'delete' and outcome = 'succeeded';
  r := r || jsonb_build_object('TC-SB462-V1.delete', case when n = 1 and m = 1 then 'pass' else format('FAIL: person %s, contact %s', n, m) end);

  -- TC-SB462-V2 (delete half): the owner cannot delete audit rows
  begin
    delete from public.crm_audit_log where user_id = ua;
    r := r || jsonb_build_object('TC-SB462-V2.owner_delete', 'FAIL: allowed');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V2.owner_delete', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- TC-SB465-V2 (delete half): B deletes nothing of A's, on every owned table
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  foreach t in array owned loop
    execute format('delete from public.%I where user_id = %L', t, ua);
    get diagnostics n = row_count;
    r := r || jsonb_build_object('TC-SB465-V2.delete.' || t, case when n = 0 then 'pass' else format('FAIL: deleted %s', n) end);
  end loop;

  -- and A's rows are all still there
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  foreach t in array owned loop
    execute format('select count(*) from public.%I where user_id = %L', t, ua) into n;
    r := r || jsonb_build_object('TC-SB465-V2.survives.' || t, case when n > 0 then 'pass' else 'FAIL: gone' end);
  end loop;

  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  begin
    delete from public.crm_audit_log where user_id = ua;
    r := r || jsonb_build_object('TC-SB462-V2.postgres_delete', 'FAIL: allowed');
  exception when others then
    r := r || jsonb_build_object('TC-SB462-V2.postgres_delete', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-SUITE PART 2 PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-SUITE PART 2 FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite2$;
