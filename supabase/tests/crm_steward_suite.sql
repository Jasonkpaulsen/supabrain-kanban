-- CRM steward run suite: TC-SB573-1..10 (ADR-CRM-006 §4.2). TC-SB573-11 is the live dry run.
--
-- Runs as two signed-in users inside one transaction that always ends by raising, so every row
-- it creates is rolled back. Run as postgres. Pass = the raised message starts with
-- "CRM-STEWARD PASS". Fixture names are invented; zq.example addresses mark fixture contacts.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  refA constant text := 'apple_contacts:qa';
  refB constant text := 'manual_json:openbrain.condo_contacts';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; fails int; st text;
  ag uuid; bA uuid; bB uuid; oQ uuid; oO uuid; gq uuid; iE uuid;
  m1a uuid; m1b uuid; m2a uuid; m2b uuid; m3a uuid; m3b uuid; m4a uuid; m4b uuid;
  m5a uuid; m5b uuid; m6a uuid; m6b uuid; m7a uuid; m7b uuid; m8a uuid; m8b uuid;
  k1a uuid; k1b uuid; k2a uuid; k2b uuid;
  x1 uuid; x2 uuid; x3 uuid; x4 uuid; x5 uuid; x6 uuid; xc6 uuid; xc3 uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; ev uuid; fC5 uuid; fC6 uuid; fE1 uuid; fE3 uuid;
  g1a uuid; g1b uuid; g2a uuid; g2b uuid; s1a uuid; s1b uuid; s3a uuid; s3b uuid;
  t1 uuid; t2 uuid; t3 uuid;
  s_dis1 jsonb; s_dis2 jsonb; s_dry jsonb; s_real jsonb; s_again jsonb;
  s_cap1 jsonb; s_cap2 jsonb; s_cap3 jsonb; s_susp jsonb; s_res jsonb; s_b jsonb; s_b2 jsonb;
  snap0 jsonb; snap1 jsonb; snap_d jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ------------------------------------------------------------------ seed: merges
  -- Equal-tier pairs created in one transaction tie on every keeper criterion, so the kept
  -- person is the smaller id; checks accept either direction. Keeper order is TC-SB573-5.
  insert into public.crm_people (display_name, given_name, family_name) values ('Thessaly Brookhart', 'Thessaly', 'Brookhart') returning id into m1a;
  insert into public.crm_people (display_name, given_name, family_name) values ('Orrin Brookhart', 'Orrin', 'Brookhart') returning id into m1b;
  insert into public.crm_contact_points (person_id, kind, value) values (m1a, 'email', 'm1@zq.example'), (m1b, 'email', 'm1@zq.example');
  insert into public.crm_people (display_name) values ('Ysolde Varga') returning id into m2a;
  insert into public.crm_people (display_name) values ('Ysolde Varga Lindqvist') returning id into m2b;
  insert into public.crm_contact_points (person_id, kind, value) values (m2a, 'phone', '+15550001001'), (m2b, 'phone', '+1 555 000 1001');
  insert into public.crm_people (display_name) values ('Duncan Morrow') returning id into m3a;
  insert into public.crm_people (display_name) values ('Philippa Strand') returning id into m3b;
  insert into public.crm_contact_points (person_id, kind, value) values (m3a, 'email', 'm3@zq.example'), (m3b, 'email', 'm3@zq.example');
  insert into public.crm_people (display_name) values ('Kestrel Ameling') returning id into m4a;
  insert into public.crm_people (display_name) values ('Kestrel Amelingsson') returning id into m4b;
  insert into public.crm_contact_points (person_id, kind, value) values (m4a, 'handle', '@zqm4'), (m4b, 'handle', '@zqm4');
  insert into public.crm_organizations (name) values ('Quarrystone Ltd') returning id into oQ;
  insert into public.crm_people (display_name) values ('Rosalind Quarry') returning id into m5a;
  insert into public.crm_people (display_name) values ('Rosalind Quarry') returning id into m5b;
  insert into public.crm_affiliations (person_id, organization_id) values (m5a, oQ), (m5b, oQ);
  insert into public.crm_people (display_name) values ('Tobiah Wrenfield') returning id into m6a;
  insert into public.crm_people (display_name) values ('Tobiah Wrenfield') returning id into m6b;
  insert into public.crm_people (display_name, family_name) values ('Corvina Lusk', 'Lusk') returning id into m7a;
  insert into public.crm_people (display_name, family_name) values ('Ambrose Lusk', 'Lusk') returning id into m7b;
  insert into public.crm_contact_points (person_id, kind, value) values (m7a, 'email', 'm7@zq.example'), (m7b, 'email', 'm7@zq.example');
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (m7b, 'health', 'restricted fixture', 'sensitive');
  insert into public.crm_people (display_name, family_name) values ('Ignatius Pell', 'Pell') returning id into m8a;
  insert into public.crm_people (display_name, family_name) values ('Mirela Pell', 'Pell') returning id into m8b;
  insert into public.crm_contact_points (person_id, kind, value) values (m8a, 'email', 'm8@zq.example'), (m8b, 'email', 'm8@zq.example');
  perform public.crm_dismiss_duplicate(m8a, m8b, 'not_same_person');
  -- keeper order
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence)
    values ('Selwyn Abernathy', 'Abernathy', 'import', refA, 0.90) returning id into k1a;
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence)
    values ('Hollis Abernathy', 'Abernathy', 'import', refB, 0.90) returning id into k1b;
  insert into public.crm_contact_points (person_id, kind, value, source_type, source_ref, confidence)
    values (k1b, 'email', 'k1@zq.example', 'import', refB, 0.90), (k1a, 'email', 'k1@zq.example', 'import', refA, 0.90);
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence)
    values ('Bastian Rook', 'Rook', 'import', refB, 0.90) returning id into k2b;
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence, confirmed_at)
    values ('Gwendolen Rook', 'Rook', 'import', refB, 0.90, now()) returning id into k2a;
  insert into public.crm_contact_points (person_id, kind, value) values (k2a, 'email', 'k2@zq.example'), (k2b, 'email', 'k2@zq.example');

  -- ------------------------------------------------------------------ seed: conflicts
  insert into public.crm_import_batches (source, format, source_label, reason_code, records_received)
    values ('vcard', 'crm.contacts.v1', 'qa', 'qa_fixture', 0) returning id into bA;
  insert into public.crm_import_batches (source, format, source_label, reason_code, records_received)
    values ('manual_json', 'crm.contacts.v1', 'openbrain.condo_contacts', 'qa_fixture', 0) returning id into bB;
  insert into public.crm_people (display_name, given_name, source_type, source_ref, confidence)
    values ('Leopold Haverty', 'Leopold', 'import', refB, 0.90) returning id into x1;
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (bA, x1, 'given_name', 'Leopold', 'Leo');
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence)
    values ('Marguerite Oyelaran', 'Oyelaran', 'import', refA, 0.90) returning id into x2;
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (bB, x2, 'family_name', 'Oyelaran', 'Oyelaran-Smythe');
  insert into public.crm_people (display_name, source_type, source_ref, confidence)
    values ('Fenwick Ostrander', 'import', refB, 0.90) returning id into x3;
  insert into public.crm_organizations (name) values ('Ostrander Cooperative') returning id into oO;
  insert into public.crm_affiliations (person_id, organization_id, role_title, source_type, source_ref, confidence)
    values (x3, oO, 'Member', 'import', refB, 0.90);
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
    values (bB, x3, 'role_title@' || oO, 'Member', 'Chair');
  insert into public.crm_people (display_name, family_name, source_type, source_ref, confidence)
    values ('Perpetua Ingle', 'Ingle', 'import', refB, 0.90) returning id into x4;
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (bB, x4, 'family_name', 'Ingle', 'Ingles');
  insert into public.crm_people (display_name, source_type, source_ref, confidence)
    values ('Caspian Merrow', 'import', refB, 0.90) returning id into x5;
  insert into public.crm_important_dates (person_id, kind, month, day, source_type, source_ref, confidence)
    values (x5, 'birthday', 3, 14, 'import', refB, 0.90);
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (bB, x5, 'birthday', '03-14', '04-14');
  insert into public.crm_people (display_name, given_name, source_type, source_ref, confidence)
    values ('Henrietta Voss', 'Henrietta', 'import', refA, 0.90) returning id into x6;
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
    values (bA, x6, 'given_name', 'Henrietta', 'Hetty') returning id into xc6;

  -- ------------------------------------------------------------------ seed: confirmation
  insert into public.crm_people (display_name, source_type, source_ref, confidence)
    values ('Isadora Penhallow', 'import', refA, 0.90) returning id into c1;
  insert into public.crm_contact_points (person_id, kind, value, source_type, source_ref, confidence)
    values (c1, 'email', 'c1@zq.example', 'import', refA, 0.90);
  insert into public.crm_people (display_name, source_type, source_ref, confidence, captured_at)
    values ('Bartholomew Quince', 'import', refB, 0.90, now() - interval '15 days') returning id into c2;
  insert into public.crm_affiliations (person_id, organization_id, role_title, source_type, source_ref, confidence, captured_at, updated_at)
    values (c2, oQ, 'Owner', 'import', refB, 0.90, now() - interval '15 days', now() - interval '15 days');
  insert into public.crm_people (display_name, source_type, source_ref, confidence, captured_at)
    values ('Ottoline Brack', 'import', refB, 0.90, now() - interval '15 days') returning id into c3;
  insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
    values (bB, c3, 'role_title@' || gen_random_uuid(), 'Owner', 'Tenant') returning id into xc3;
  insert into public.crm_people (display_name, source_type, source_ref, confidence, captured_at)
    values ('Wilhelmina Strake', 'import', refB, 0.90, now() - interval '5 days') returning id into c4;
  insert into public.crm_people (display_name) values ('Evander Thorne') returning id into ev;
  insert into public.crm_facts (person_id, fact_type, value) values (ev, 'hobby', 'zq chess');
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
    values (ev, 'hobby', 'ZQ Chess ', 'agent', 'qa_agent', 0.50) returning id into fC5;
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
    values (ev, 'hobby', 'zq kites', 'agent', 'qa_agent', 0.50) returning id into fC6;

  -- ------------------------------------------------------------------ seed: gray zone and expiry
  insert into public.crm_people (display_name, created_at) values ('Marisande Oakvale', now() - interval '31 days') returning id into g1a;
  insert into public.crm_people (display_name, created_at) values ('Marisande Oakvale', now() - interval '31 days') returning id into g1b;
  insert into public.crm_people (display_name, created_at) values ('Peregrine Halloway', now() - interval '31 days') returning id into g2a;
  insert into public.crm_people (display_name, created_at) values ('Peregrine Halloway', now() - interval '31 days') returning id into g2b;
  insert into public.crm_groups (name) values ('QA Steward Group') returning id into gq;
  insert into public.crm_group_members (group_id, person_id) values (gq, g2a), (gq, g2b);
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence, captured_at, updated_at)
    values (ev, 'note', 'zq old guess', 'agent', 'qa_agent', 0.50, now() - interval '61 days', now() - interval '61 days') returning id into fE1;
  insert into public.crm_facts (person_id, fact_type, value, sensitivity, source_type, source_ref, confidence, captured_at, updated_at)
    values (ev, 'note', 'zq old restricted', 'sensitive', 'agent', 'qa_agent', 0.50, now() - interval '61 days', now() - interval '61 days') returning id into fE3;
  insert into public.crm_interactions (interaction_type, occurred_at, title, source_type, source_ref, confidence, captured_at, updated_at)
    values ('meeting', now() - interval '62 days', 'zq old meeting', 'import', 'google_calendar:qa', 0.60,
            now() - interval '61 days', now() - interval '61 days') returning id into iE;

  -- ------------------------------------------------------------------ TC-SB573-1: kill switch
  snap0 := jsonb_build_object('decisions', (select count(*) from public.crm_steward_decisions),
                              'live', (select count(*) from public.crm_people where not archived),
                              'open', (select count(*) from public.crm_import_conflicts where status = 'open'));
  s_dis1 := public.crm_steward_run(false);
  insert into public.agents (user_id, name, system_prompt, automation_enabled)
    values (ua, 'CRM Data Steward', 'QA fixture steward agent', false) returning id into ag;
  s_dis2 := public.crm_steward_run(false);
  snap1 := jsonb_build_object('decisions', (select count(*) from public.crm_steward_decisions),
                              'live', (select count(*) from public.crm_people where not archived),
                              'open', (select count(*) from public.crm_import_conflicts where status = 'open'));
  r := r || jsonb_build_object('TC-SB573-1', case
         when (s_dis1->>'disabled')::boolean and (s_dis2->>'disabled')::boolean and snap0 = snap1
         then 'pass' else format('FAIL: %s / %s / %s -> %s', s_dis1, s_dis2, snap0, snap1) end);

  -- ------------------------------------------------------------------ TC-SB573-2: dry run
  update public.agents set automation_enabled = true where id = ag;
  snap0 := jsonb_build_object(
    'decisions', (select count(*) from public.crm_steward_decisions),
    'live', (select count(*) from public.crm_people where not archived),
    'confirmed', (select count(*) from public.crm_people where confirmed_at is not null),
    'open', (select count(*) from public.crm_import_conflicts where status = 'open'),
    'dismissals', (select count(*) from public.crm_duplicate_dismissals),
    'arch_facts', (select count(*) from public.crm_facts where archived),
    'arch_int', (select count(*) from public.crm_interactions where archived),
    'merges', (select count(*) from public.crm_merge_log),
    'leo', (select given_name from public.crm_people where id = x1));
  s_dry := public.crm_steward_run(true);
  snap_d := jsonb_build_object(
    'decisions', (select count(*) from public.crm_steward_decisions),
    'live', (select count(*) from public.crm_people where not archived),
    'confirmed', (select count(*) from public.crm_people where confirmed_at is not null),
    'open', (select count(*) from public.crm_import_conflicts where status = 'open'),
    'dismissals', (select count(*) from public.crm_duplicate_dismissals),
    'arch_facts', (select count(*) from public.crm_facts where archived),
    'arch_int', (select count(*) from public.crm_interactions where archived),
    'merges', (select count(*) from public.crm_merge_log),
    'leo', (select given_name from public.crm_people where id = x1));
  s_real := public.crm_steward_run(false);
  r := r || jsonb_build_object('TC-SB573-2', case
         when snap0 = snap_d and (s_dry->>'dry_run')::boolean and not (s_real->>'dry_run')::boolean
          and (s_dry - 'run_id' - 'dry_run') = (s_real - 'run_id' - 'dry_run')
          and (s_real->>'decisions')::int > 0
         then 'pass' else format('FAIL: snap %s -> %s; dry %s; real %s', snap0, snap_d, s_dry, s_real) end);

  -- ------------------------------------------------------------------ TC-SB573-3: rule (a)
  r := r || jsonb_build_object('TC-SB573-3', case
         when (select count(*) from public.crm_people a, public.crm_people b
                where a.id = m1a and b.id = m1b and (a.merged_into_id = b.id or b.merged_into_id = a.id)) = 1
          and (select count(*) from public.crm_people a, public.crm_people b
                where a.id = m2a and b.id = m2b and (a.merged_into_id = b.id or b.merged_into_id = a.id)) = 1
          and (select not archived from public.crm_people where id = m3a) and (select not archived from public.crm_people where id = m3b)
          and (select not archived from public.crm_people where id = m4a) and (select not archived from public.crm_people where id = m4b)
          and exists (select 1 from public.crm_steward_decisions d join public.crm_merge_log l on l.id = d.merge_log_id
                       where d.decision = 'auto_merge' and d.rule = 'auto_merge_contact' and d.entity_id in (m1a, m1b)
                         and l.undo is not null and d.run_id = (s_real->>'run_id')::uuid)
         then 'pass' else 'FAIL: rule (a) merges' end);

  -- ------------------------------------------------------------------ TC-SB573-5: keeper order
  r := r || jsonb_build_object('TC-SB573-5', case
         when (select merged_into_id = k1a from public.crm_people where id = k1b)
          and (select merged_into_id = k2a from public.crm_people where id = k2b)
         then 'pass' else 'FAIL: keeper order' end);

  -- ------------------------------------------------------------------ TC-SB573-6: conflicts by tier
  r := r || jsonb_build_object('TC-SB573-6', case
         when (select status from public.crm_import_conflicts where person_id = x1) = 'took_incoming'
          and (select given_name = 'Leo' and meta->>'confirmed_by' = 'policy:auto_resolve' from public.crm_people where id = x1)
          and (select status from public.crm_import_conflicts where person_id = x2) = 'kept_existing'
          and (select status from public.crm_import_conflicts where person_id = x3) = 'took_incoming'
          and (select role_title = 'Chair' and meta->>'confirmed_by' = 'policy:auto_resolve' from public.crm_affiliations where person_id = x3)
          and (select status from public.crm_import_conflicts where person_id = x4) = 'kept_existing'
          and (select status from public.crm_import_conflicts where person_id = x5) = 'kept_existing'
          and (select month = 3 from public.crm_important_dates where person_id = x5)
          and (select status from public.crm_import_conflicts where id = xc6) = 'open'
          and (s_real->'conflicts'->>'left_tier_a_vs_a')::int = 1
         then 'pass' else format('FAIL: %s', s_real->'conflicts') end);

  -- ------------------------------------------------------------------ TC-SB573-7: confirmation
  r := r || jsonb_build_object('TC-SB573-7', case
         when (select confirmed_at is not null and meta->>'confirmed_by' = 'policy:tier_a' from public.crm_people where id = c1)
          and (select confirmed_at is not null from public.crm_contact_points where person_id = c1)
          and (select confirmed_at is not null and meta->>'confirmed_by' = 'policy:tier_b_14d' from public.crm_people where id = c2)
          and (select confirmed_at is not null from public.crm_affiliations where person_id = c2)
          and (select confirmed_at is null from public.crm_people where id = c3)
          and (select status from public.crm_import_conflicts where id = xc3) = 'open'
          and (select confirmed_at is null from public.crm_people where id = c4)
          and (select confirmed_at is not null and meta->>'confirmed_by' = 'policy:tier_c_corroborated' from public.crm_facts where id = fC5)
          and (select confirmed_at is null from public.crm_facts where id = fC6)
         then 'pass' else format('FAIL: %s', s_real->'confirmed') end);

  -- ------------------------------------------------------------------ TC-SB573-8: gray zone and expiry
  r := r || jsonb_build_object('TC-SB573-8', case
         when exists (select 1 from public.crm_duplicate_dismissals d where d.reason_code = 'auto_dismiss_gray_zone'
                       and d.person_a = least(g1a, g1b) and d.person_b = greatest(g1a, g1b))
          and not exists (select 1 from public.crm_duplicate_dismissals d
                           where d.person_a = least(g2a, g2b) and d.person_b = greatest(g2a, g2b))
          and not exists (select 1 from public.crm_duplicate_dismissals d
                           where d.person_a = least(m6a, m6b) and d.person_b = greatest(m6a, m6b))
          and (select archived from public.crm_facts where id = fE1)
          and (select archived from public.crm_interactions where id = iE)
          and (select not archived from public.crm_facts where id = fE3)
          and (s_real->'gray_zone'->>'left_for_jason')::int >= 1
         then 'pass' else format('FAIL: %s %s', s_real->'gray_zone', s_real->'expired') end);

  -- ------------------------------------------------------------------ TC-SB573-9: bounded, idempotent, logged
  s_again := public.crm_steward_run(false);
  insert into public.crm_people (display_name, source_type, source_ref, confidence) values ('Aurelio Drummond', 'import', refA, 0.90) returning id into t1;
  insert into public.crm_people (display_name, source_type, source_ref, confidence) values ('Benedetta Sorrel', 'import', refA, 0.90) returning id into t2;
  insert into public.crm_people (display_name, source_type, source_ref, confidence) values ('Cosimo Larkspur', 'import', refA, 0.90) returning id into t3;
  s_cap1 := public.crm_steward_run(false, 2);
  s_cap2 := public.crm_steward_run(false);
  s_cap3 := public.crm_steward_run(false);
  select count(*) into n from public.crm_steward_decisions where run_id = (s_real->>'run_id')::uuid;
  select count(*) into m from public.crm_steward_decisions d
   where to_jsonb(d)::text ~* '(zq\.example|brookhart|varga|quarry|leopold|penhallow|oakvale|chess)';
  r := r || jsonb_build_object('TC-SB573-9', case
         when (s_again->>'decisions')::int = 0
          and (s_cap1->>'decisions')::int = 2 and (s_cap1->>'capped')::boolean
          and (s_cap2->>'decisions')::int = 1 and (s_cap3->>'decisions')::int = 0
          and n = (s_real->>'decisions')::int and m = 0
         then 'pass' else format('FAIL: again %s cap %s/%s/%s run rows %s content %s',
                                 s_again->'decisions', s_cap1->'decisions', s_cap2->'decisions', s_cap3->'decisions', n, m) end);

  -- ------------------------------------------------------------------ TC-SB573-4: rule (b), exclusions, suspension
  insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_wrong_merge_rate', 'crm_steward_decisions', 'qa_suspend');
  insert into public.crm_people (display_name, family_name) values ('Lucasta Ferrand', 'Ferrand') returning id into s1a;
  insert into public.crm_people (display_name, family_name) values ('Odile Ferrand', 'Ferrand') returning id into s1b;
  insert into public.crm_contact_points (person_id, kind, value) values (s1a, 'email', 's1@zq.example'), (s1b, 'email', 's1@zq.example');
  s_susp := public.crm_steward_run(false);
  k := (select count(*) from public.crm_people where id in (s1a, s1b) and not archived);
  insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume');
  s_res := public.crm_steward_run(false);
  r := r || jsonb_build_object('TC-SB573-4', case
         when (select count(*) from public.crm_people a, public.crm_people b
                where a.id = m5a and b.id = m5b and (a.merged_into_id = b.id or b.merged_into_id = a.id)) = 1
          and exists (select 1 from public.crm_steward_decisions where decision = 'auto_merge' and rule = 'auto_merge_name_org' and entity_id in (m5a, m5b))
          and (select count(*) from public.crm_people where id in (m6a, m6b) and not archived) = 2
          and (select count(*) from public.crm_people where id in (m7a, m7b) and not archived) = 2
          and (select count(*) from public.crm_people where id in (m8a, m8b) and not archived) = 2
          and (s_susp->'merges'->>'suspended')::boolean and (s_susp->'merges'->>'merged')::int = 0 and k = 2
          and not (s_res->'merges'->>'suspended')::boolean and (s_res->'merges'->>'merged')::int = 1
         then 'pass' else format('FAIL: suspended %s resumed %s', s_susp->'merges', s_res->'merges') end);

  -- ------------------------------------------------------------------ TC-SB573-10: owner-only and posture
  insert into public.crm_people (display_name, family_name) values ('Rafferty Quill', 'Quill') returning id into s3a;
  insert into public.crm_people (display_name, family_name) values ('Saoirse Quill', 'Quill') returning id into s3b;
  insert into public.crm_contact_points (person_id, kind, value) values (s3a, 'email', 's3@zq.example'), (s3b, 'email', 's3@zq.example');
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  s_b := public.crm_steward_run(false);
  s_b2 := public.crm_steward_run(true);
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  st := null;
  begin perform public.crm_steward_run(true);
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB573-10', case
         when (s_b->>'disabled')::boolean and (s_b2->>'dry_run')::boolean
          and (select count(*) from public.crm_people where id in (s3a, s3b) and not archived) = 2
          and st = '42501'
          and (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                where s.nspname = 'public' and p.proname = 'crm_policy_confirm_person') = 1
          and not exists (select 1 from pg_proc where oid = 'public.crm_steward_run(boolean,integer)'::regprocedure
                           and (prosecdef or not proconfig @> array['search_path=""']))
          and not has_function_privilege('anon', 'public.crm_steward_run(boolean,integer)', 'execute')
         then 'pass' else format('FAIL: b %s / %s, no-session %s', s_b, s_b2, st) end);

  select count(*) into fails from jsonb_each(r) where value <> '"pass"'::jsonb;
  if fails = 0 then
    raise exception 'CRM-STEWARD PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-STEWARD FAIL (% of % checks): % | real run %', fails, (select count(*) from jsonb_object_keys(r)), r::text, s_real;
  end if;
end $suite$;
