-- CRM steward digest suite: TC-SB574-1..14 (SB-574; ADR-CRM-006 §8, SB-574 amendment).
--
-- Covers crm_steward_digest (every item type from fixtures and absent otherwise; strong pairs listed
-- if and only if crm_steward_run does not merge them; no PII; read-only preview; delivery routing;
-- weekly idempotency; 50-line cap) and the SB-574 changes to crm_steward_scheduled (weekly digest,
-- immediate escalation of a failed run, de-duplicated while open, never breaking the run log).
--
-- Runs as postgres, acting as two signed-in users: ua (fixture tenant: fixture people, a fixture
-- steward agent with automation on, synthetic agent_runs; no SB project, so no tickets) and ub (the
-- owner: delivery, escalation and the weekly cron command; every ticket, run and decision is rolled
-- back). One transaction that always ends by raising, and every case rolls back its own sub-block.
-- TC-SB574-15 is the regression run of the other steward suites (recorded separately).
-- Pass = the raised message starts with "CRM-STEWARD-DIGEST PASS". Fixture names are invented;
-- zq.example addresses, +1 555 010 42xx numbers and @zqsb574 handles mark fixture contacts. The
-- message carries only counts, tags, booleans, sqlstates and ticket codes.

do $suite$
declare
  ua  constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';   -- fixture tenant
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  aid constant uuid := '35c61865-2677-42fd-aad3-d2aa8fa81e85';   -- owner's CRM Data Steward
  sb  constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  md5_digest    constant text := 'c5272b5c8a20fd8b2f4003207aec4bbe';
  md5_scheduled constant text := '018a00808c60d53efc0c8f819bef72cc';
  md5_skill     constant text := '678af7004d3093db1a5662e353d73be6';
  rb  constant text := '__sb574_rollback__';
  r jsonb := '{}'::jsonb;
  pr jsonb; d jsonb; d2 jsonb; res jsonb; res2 jsonb;
  n int; m int; k int; i int; fails int; st text; msg text; txt text; cmd text; tags text; tags2 text;
  a1 uuid; b1 uuid; ag uuid; org uuid; grp uuid; rt uuid; ib uuid; ix uuid; ml uuid; dec_id uuid; vid uuid;
  c0 jsonb; c1 jsonb; epic uuid; wi public.work_items%rowtype; ar public.agent_runs%rowtype;
  wi0 int; wi1 int; runs0 int; runs1 int; ec0 int; ec1 int; esc text; esc2 text;
begin
  if exists (select 1 from public.crm_steward_decisions where user_id = ua)
     or exists (select 1 from public.crm_people where user_id = ua)
     or exists (select 1 from public.agents where user_id = ua and name = 'CRM Data Steward') then
    raise exception 'CRM-STEWARD-DIGEST FAIL: fixture tenant is not empty';
  end if;
  select w.id into epic from public.work_items w where w.ticket_code = 'SB-570';

  -- ------------------------------------------------ TC-SB574-1..5: items from fixtures, cross-checked with the steward
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.agents (user_id, name, system_prompt, automation_enabled)
      values (ua, 'CRM Data Steward', 'QA fixture steward agent (SB-574)', true) returning id into ag;
    pr := '{}'::jsonb;
    -- strong pairs (shared contact point)
    insert into public.crm_people (display_name, given_name, family_name) values ('Brannoch Edevane', 'Brannoch', 'Edevane') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Morwen Edevane', 'Morwen', 'Edevane') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'email', 'sb574-s1@zq.example'), (b1, 'email', 'sb574-s1@zq.example');
    pr := pr || jsonb_build_object('S1', jsonb_build_array(a1, b1));          -- email + same surname: steward merges
    insert into public.crm_people (display_name, given_name, family_name) values ('Jessamy Thornquist', 'Jessamy', 'Thornquist') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Jess Thornquist', 'Jess', 'Thornquist') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'phone', '+15550104201'), (b1, 'phone', '+1 555 010 4201');
    pr := pr || jsonb_build_object('S2', jsonb_build_array(a1, b1));          -- phone + compatible given names: merges
    insert into public.crm_people (display_name, given_name, family_name) values ('Corwin Ashgrove', 'Corwin', 'Ashgrove') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Petrina Halloran', 'Petrina', 'Halloran') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'email', 'sb574-s3@zq.example'), (b1, 'email', 'sb574-s3@zq.example');
    pr := pr || jsonb_build_object('S3', jsonb_build_array(a1, b1));          -- email, unrelated names: not merged
    insert into public.crm_people (display_name, given_name, family_name) values ('Ingram Feldwick', 'Ingram', 'Feldwick') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Petronel Feldwick', 'Petronel', 'Feldwick') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'phone', '+15550104204'), (b1, 'phone', '+15550104204');
    pr := pr || jsonb_build_object('S4', jsonb_build_array(a1, b1));          -- relatives on a landline: not merged
    insert into public.crm_people (display_name, given_name, family_name) values ('Quenby Stratton', 'Quenby', 'Stratton') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Dorian Valcourt', 'Dorian', 'Valcourt') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'handle', '@zqsb574s5'), (b1, 'handle', '@zqsb574s5');
    pr := pr || jsonb_build_object('S5', jsonb_build_array(a1, b1));          -- handle only: not merged
    insert into public.crm_people (display_name, given_name, family_name) values ('Rosamund Clevedon', 'Rosamund', 'Clevedon') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Hallam Clevedon', 'Hallam', 'Clevedon') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'email', 'sb574-s6@zq.example'), (b1, 'email', 'sb574-s6@zq.example');
    insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (a1, 'health', 'zq restricted fixture', 'sensitive');
    pr := pr || jsonb_build_object('S6', jsonb_build_array(a1, b1));          -- would merge, sensitive fact: restricted
    insert into public.crm_people (display_name, given_name, family_name) values ('Elowen Trevanion', 'Elowen', 'Trevanion') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Jory Trevanion', 'Jory', 'Trevanion') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'email', 'sb574-s7@zq.example'), (b1, 'email', 'sb574-s7@zq.example');
    insert into public.crm_interactions (interaction_type, occurred_at, title, sensitivity, source_type)
      values ('meeting', now() - interval '1 day', 'zq restricted meeting', 'highly_sensitive', 'manual') returning id into ix;
    insert into public.crm_interaction_participants (interaction_id, person_id) values (ix, b1);
    pr := pr || jsonb_build_object('S7', jsonb_build_array(a1, b1));          -- would merge, highly sensitive interaction: restricted
    insert into public.crm_organizations (name) values ('Zq Grenfell Works') returning id into org;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ottilie Grenfell', 'Ottilie', 'Grenfell') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ottilie Grenfell', 'Ottilie', 'Grenfell') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'handle', '@zqsb574s9'), (b1, 'handle', '@zqsb574s9');
    insert into public.crm_affiliations (person_id, organization_id) values (a1, org), (b1, org);
    pr := pr || jsonb_build_object('S9', jsonb_build_array(a1, b1));          -- strong by handle, same name + org: rule (b) merges
    -- possible pairs (names only)
    insert into public.crm_organizations (name) values ('Zq Lantern Guild') returning id into org;
    insert into public.crm_people (display_name, given_name, family_name) values ('Tamsin Velloway', 'Tamsin', 'Velloway') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Tamsin Vellowey', 'Tamsin', 'Vellowey') returning id into b1;
    insert into public.crm_affiliations (person_id, organization_id) values (a1, org), (b1, org);
    pr := pr || jsonb_build_object('G1', jsonb_build_array(a1, b1));          -- similar names + organization
    insert into public.crm_groups (name) values ('Zq Harbour Choir') returning id into grp;
    insert into public.crm_people (display_name, given_name, family_name) values ('Aurick Penhalt', 'Aurick', 'Penhalt') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Aurick Penhalte', 'Aurick', 'Penhalte') returning id into b1;
    insert into public.crm_group_members (group_id, person_id) values (grp, a1), (grp, b1);
    pr := pr || jsonb_build_object('G2', jsonb_build_array(a1, b1));          -- similar names + group
    insert into public.crm_relationship_types (code, label, is_symmetric) values ('qa_sb574_peer', 'QA peer', true) returning id into rt;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ysolde Brackwater', 'Ysolde', 'Brackwater') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ysolde Brackwaters', 'Ysolde', 'Brackwaters') returning id into b1;
    insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id, source_type) values (a1, b1, rt, 'manual');
    pr := pr || jsonb_build_object('G3', jsonb_build_array(a1, b1));          -- similar names + relationship
    insert into public.crm_people (display_name, given_name, family_name) values ('Fennick Oatridge', 'Fennick', 'Oatridge') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Fennick Oatridges', 'Fennick', 'Oatridges') returning id into b1;
    pr := pr || jsonb_build_object('G4', jsonb_build_array(a1, b1));          -- similar names, no shared context: no item
    insert into public.crm_organizations (name) values ('Zq Quarnby Mill') returning id into org;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ottoline Quarnby', 'Ottoline', 'Quarnby') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ottoline Quarnby', 'Ottoline', 'Quarnby') returning id into b1;
    insert into public.crm_affiliations (person_id, organization_id) values (a1, org), (b1, org);
    pr := pr || jsonb_build_object('G5', jsonb_build_array(a1, b1));          -- same name + organization (possible): rule (b) merges
    -- import conflicts: tier A vs A (item) and tier B vs A (steward resolves; no item)
    insert into public.crm_import_batches (source, format, source_label, reason_code, records_received)
      values ('vcard', 'crm.contacts.v1', 'qa', 'qa_fixture', 0) returning id into ib;
    insert into public.crm_people (display_name, given_name, source_type, source_ref, confidence)
      values ('Henrika Vossberg', 'Henrika', 'import', 'apple_contacts:qa', 0.90) returning id into a1;
    insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (ib, a1, 'given_name', 'Henrika', 'Rika');
    pr := pr || jsonb_build_object('C1', jsonb_build_array(a1, a1));
    insert into public.crm_people (display_name, given_name, source_type, source_ref, confidence)
      values ('Leopolda Havers', 'Leopolda', 'import', 'manual_json:openbrain.condo_contacts', 0.90) returning id into b1;
    insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value) values (ib, b1, 'given_name', 'Leopolda', 'Polly');
    pr := pr || jsonb_build_object('C2', jsonb_build_array(b1, b1));

    reset role;
    c0 := jsonb_build_object('wi', (select count(*) from public.work_items), 'dec', (select count(*) from public.crm_steward_decisions),
                             'runs', (select count(*) from public.agent_runs), 'people', (select count(*) from public.crm_people where not archived),
                             'conf', (select count(*) from public.crm_import_conflicts where status = 'open'));
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    d := public.crm_steward_digest(false);
    d2 := public.crm_steward_digest();                                -- default = preview
    reset role;
    c1 := jsonb_build_object('wi', (select count(*) from public.work_items), 'dec', (select count(*) from public.crm_steward_decisions),
                             'runs', (select count(*) from public.agent_runs), 'people', (select count(*) from public.crm_people where not archived),
                             'conf', (select count(*) from public.crm_import_conflicts where status = 'open'));

    -- TC-SB574-1: item types from fixtures
    select string_agg(t.key, ',' order by t.key) into tags from jsonb_each(pr) t
     where exists (select 1 from jsonb_array_elements(d->'items') e where e->>'type' = 'strong_pair_not_merged'
                    and least((e->>'person_a')::uuid, (e->>'person_b')::uuid) = least((t.value->>0)::uuid, (t.value->>1)::uuid)
                    and greatest((e->>'person_a')::uuid, (e->>'person_b')::uuid) = greatest((t.value->>0)::uuid, (t.value->>1)::uuid));
    select string_agg(t.key, ',' order by t.key) into tags2 from jsonb_each(pr) t
     where exists (select 1 from jsonb_array_elements(d->'items') e where e->>'type' = 'restricted_blocks_merge'
                    and least((e->>'person_a')::uuid, (e->>'person_b')::uuid) = least((t.value->>0)::uuid, (t.value->>1)::uuid)
                    and greatest((e->>'person_a')::uuid, (e->>'person_b')::uuid) = greatest((t.value->>0)::uuid, (t.value->>1)::uuid));
    select string_agg(t.key || ':' || (e->>'shares'), ',' order by t.key) into msg
      from jsonb_each(pr) t join jsonb_array_elements(d->'items') e on e->>'type' = 'gray_zone_shared_context'
       and least((e->>'person_a')::uuid, (e->>'person_b')::uuid) = least((t.value->>0)::uuid, (t.value->>1)::uuid)
       and greatest((e->>'person_a')::uuid, (e->>'person_b')::uuid) = greatest((t.value->>0)::uuid, (t.value->>1)::uuid);
    select string_agg(t.key, ',' order by t.key) into txt from jsonb_each(pr) t
     where exists (select 1 from jsonb_array_elements(d->'items') e where e->>'type' = 'tier_a_conflict'
                    and (e->>'person_id')::uuid = (t.value->>0)::uuid and e->>'field' = 'given_name' and e ? 'conflict_id');
    select count(*) into n from jsonb_array_elements(d->'items') e where e->>'type' in ('auto_merge_suspended', 'wrong_merge_not_undone', 'steward_health');
    r := r || jsonb_build_object('TC-SB574-1', case
           when tags = 'S3,S4,S5' and tags2 = 'S6,S7' and replace(coalesce(msg, ''), ',G5:organization', '') = 'G1:organization,G2:group,G3:relationship'
            and txt = 'C1' and n = 0 and (d->>'fyi_merge_count')::int = 0
            and (d->>'item_count')::int = 9 + (case when coalesce(msg, '') ~ 'G5:' then 1 else 0 end)
            and (d->>'item_count')::int = jsonb_array_length(d->'items') and (d->>'over_target')::boolean = ((d->>'item_count')::int >= 5)
            and not (d->>'delivered')::boolean and d->'work_item' = 'null'::jsonb
           then 'pass' else format('FAIL: strong_not_merged [%s] restricted [%s] gray [%s] tier_a [%s] other %s count %s',
                                   tags, tags2, msg, txt, n, d->'item_count') end);
    r := r || jsonb_build_object('TC-SB574-1.evidence', format('items %s: strong_not_merged %s, restricted %s, gray %s, tier_a %s',
                                   d->'item_count', tags, tags2, msg, txt));
    -- evidence kinds only
    select string_agg(distinct x, ',' order by x) into tags from jsonb_array_elements(d->'items') e, jsonb_array_elements_text(e->'evidence') x
     where e->>'type' = 'strong_pair_not_merged';

    -- TC-SB574-4: no PII anywhere in the digest (and the preview default equals the explicit preview)
    txt := lower(d::text);
    select count(*) into n from public.crm_people p where p.user_id = ua and strpos(txt, lower(p.display_name)) > 0;
    select count(*) into m from public.crm_contact_points c where c.user_id = ua
       and (strpos(txt, lower(c.value)) > 0 or strpos(txt, lower(coalesce(c.value_normalized, c.value))) > 0);
    select count(*) into k from (select name from public.crm_organizations where user_id = ua
                                 union all select name from public.crm_groups where user_id = ua) o where strpos(txt, lower(o.name)) > 0;
    r := r || jsonb_build_object('TC-SB574-4', case
           when n = 0 and m = 0 and k = 0 and txt !~ '@|zq\.example|both at|same email |same phone |similar names'
            and tags = 'other,same email,same phone'
            and (d - 'items' - 'fyi_merges') - 'work_item' = (d2 - 'items' - 'fyi_merges') - 'work_item'
           then 'pass' else format('FAIL: names %s contact values %s org/group names %s raw-reason-or-contact text %s evidence kinds [%s]',
                                   n, m, k, txt ~ '@|zq\.example|both at|same email |same phone |similar names', tags) end);

    -- TC-SB574-5: the preview writes nothing
    r := r || jsonb_build_object('TC-SB574-5', case when c0 = c1 then 'pass' else format('FAIL: %s -> %s', c0, c1) end);

    -- TC-SB574-2: strong_pair_not_merged lists exactly the strong pairs the steward does not merge
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    res := public.crm_steward_run(false);
    reset role;
    select string_agg(t.key, ',' order by t.key) into tags from jsonb_each(pr) t
      join public.crm_people x on x.id = (t.value->>0)::uuid join public.crm_people y on y.id = (t.value->>1)::uuid
     where t.key <> 'C1' and t.key <> 'C2' and (x.merged_into_id = y.id or y.merged_into_id = x.id);
    r := r || jsonb_build_object('TC-SB574-2', case
           when tags = 'G5,S1,S2,S9' and (res->'merges'->>'errors')::int = 0 and not (res->'merges'->>'suspended')::boolean
           then 'pass' else format('FAIL: steward merged [%s] (expected G5,S1,S2,S9; the digest listed S3,S4,S5 as not merged and S6,S7 as restricted)', tags) end);
    r := r || jsonb_build_object('TC-SB574-2.evidence', format('steward merged %s; digest strong_pair_not_merged S3,S4,S5; restricted S6,S7', tags));

    -- TC-SB574-3 (probe): a pair the steward merges by rule (b) is not offered to Jason as a gray-zone item
    r := r || jsonb_build_object('TC-SB574-3', case
           when coalesce(msg, '') !~ 'G5:' then 'pass'
           else 'FAIL: same-name + same-organization pair G5 (strength possible) is listed as gray_zone_shared_context:organization, but crm_steward_run merges it (auto_merge_name_org)' end);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB574-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
  end;

  -- ------------------------------------------------ TC-SB574-6: suspension, wrong merges not undone, FYI merges
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.agents (user_id, name, system_prompt, automation_enabled)
      values (ua, 'CRM Data Steward', 'QA fixture steward agent (SB-574)', true) returning id into ag;
    insert into public.crm_people (display_name, given_name, family_name) values ('Brannoch Edevane', 'Brannoch', 'Edevane') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Morwen Edevane', 'Morwen', 'Edevane') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'email', 'sb574-s1@zq.example'), (b1, 'email', 'sb574-s1@zq.example');
    insert into public.crm_people (display_name, given_name, family_name) values ('Jessamy Thornquist', 'Jessamy', 'Thornquist') returning id into a1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Jess Thornquist', 'Jess', 'Thornquist') returning id into b1;
    insert into public.crm_contact_points (person_id, kind, value) values (a1, 'phone', '+15550104201'), (b1, 'phone', '+1 555 010 4201');
    res := public.crm_steward_run(false);                                         -- 2 real merges with undo handles
    d := public.crm_steward_digest(false);
    n := (select count(*) from jsonb_array_elements(d->'items') e where e->>'type' in ('auto_merge_suspended', 'wrong_merge_not_undone'));
    select x0.id, x0.merge_log_id into dec_id, ml from public.crm_steward_decisions x0 where x0.decision = 'auto_merge' order by x0.seq limit 1;
    res2 := public.crm_steward_record_verdict(dec_id, 'wrong');                    -- also suspends auto-merge
    d2 := public.crm_steward_digest(false);
    st := (select string_agg(e->>'type', ',' order by e->>'type') from jsonb_array_elements(d2->'items') e
            where e->>'type' in ('auto_merge_suspended', 'wrong_merge_not_undone'));
    k := (select count(*) from jsonb_array_elements(d2->'items') e where e->>'type' = 'wrong_merge_not_undone'
           and (e->>'decision_id')::uuid = dec_id and (e->>'merge_log_id')::uuid = ml and (e->>'verdict_id')::uuid = (res2->>'verdict_id')::uuid);
    m := (select count(*) from jsonb_array_elements(d2->'items') e where e->>'type' = 'auto_merge_suspended'
           and (e->>'tripped_by_verdict')::uuid = (res2->>'verdict_id')::uuid);
    i := (select count(*) from jsonb_array_elements(d2->'fyi_merges') e where not (e->>'undone')::boolean and e ? 'merge_log_id');
    perform public.crm_unmerge(ml, 'qa_wrong_merge');
    res := public.crm_steward_digest(false);
    tags := (select string_agg(e->>'type', ',') from jsonb_array_elements(res->'items') e where e->>'type' = 'wrong_merge_not_undone');
    tags2 := (select string_agg((e->>'undone'), ',' order by e->>'undone') from jsonb_array_elements(res->'fyi_merges') e);
    -- a later 'correct' supersedes a 'wrong' on the other merge
    select x0.id into dec_id from public.crm_steward_decisions x0 where x0.decision = 'auto_merge' and x0.merge_log_id <> ml order by x0.seq limit 1;
    perform public.crm_steward_record_verdict(dec_id, 'wrong');
    perform public.crm_steward_record_verdict(dec_id, 'correct');
    res2 := public.crm_steward_digest(false);
    txt := (select string_agg(e->>'type', ',') from jsonb_array_elements(res2->'items') e where e->>'type' = 'wrong_merge_not_undone');
    insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('resume', 'qa_reviewed', 'crm_steward_decisions', 'qa_resume');
    msg := (select string_agg(e->>'type', ',') from jsonb_array_elements(public.crm_steward_digest(false)->'items') e where e->>'type' = 'auto_merge_suspended');
    reset role;
    -- an 8-day-old automatic merge is not in the FYI list
    insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code, created_at)
      values (ua, ua, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture', now() - interval '8 days');
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    c0 := public.crm_steward_digest(false);
    reset role;
    r := r || jsonb_build_object('TC-SB574-6', case
           when n = 0 and st = 'auto_merge_suspended,wrong_merge_not_undone' and k = 1 and m = 1
            and (d->>'fyi_merge_count')::int = 2 and i = 2
            and tags is null and tags2 = 'false,true' and txt is null and msg is null and (c0->>'fyi_merge_count')::int = 2
           then 'pass' else format('FAIL: before %s, after wrong [%s] wrong ok %s suspend ok %s, fyi %s/%s, after unmerge [%s] undone flags [%s], after correct [%s], after resume [%s], fyi with old %s',
                                   n, st, k, m, d->'fyi_merge_count', i, tags, tags2, txt, msg, c0->'fyi_merge_count') end);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB574-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
  end;

  -- ------------------------------------------------ TC-SB574-7: steward health: failed runs (7 days), capped daily runs on 3 UTC days
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.agents (user_id, name, system_prompt, automation_enabled)
      values (ua, 'CRM Data Steward', 'QA fixture steward agent (SB-574)', false) returning id into ag;
    reset role;
    msg := '';
    -- (a) nothing
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    d := public.crm_steward_digest(false);
    msg := msg || 'none=' || (select count(*) from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health') || ' ';
    -- (b) a failed run 8 days ago does not count; one 6 days ago does
    insert into public.agent_runs (user_id, agent_id, started_at, finished_at, status, trigger_type, run_metadata)
      values (ua, ag, now() - interval '8 days', now() - interval '8 days', 'failed', 'scheduled', '{"task":"daily"}');
    d := public.crm_steward_digest(false);
    msg := msg || 'old_failed=' || (select count(*) from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health') || ' ';
    insert into public.agent_runs (user_id, agent_id, started_at, finished_at, status, trigger_type, run_metadata)
      values (ua, ag, now() - interval '6 days', now() - interval '6 days', 'failed', 'scheduled', '{"task":"daily"}') returning id into ix;
    d := public.crm_steward_digest(false);
    msg := msg || 'failed=' || coalesce((select (e->>'failed_runs') || '/' || (e->'failed_run_ids'->>0 = ix::text)::text || '/' || (e->>'capped_3_days')
                                          from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health'), 'none') || ' ';
    reset role;
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := msg || 'error ' || sqlstate || ' ' || sqlerrm; end if;
  end;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.agents (user_id, name, system_prompt, automation_enabled)
      values (ua, 'CRM Data Steward', 'QA fixture steward agent (SB-574)', false) returning id into ag;
    -- capped completed daily runs today and yesterday (UTC): 2 days, no item
    insert into public.agent_runs (user_id, agent_id, started_at, finished_at, status, trigger_type, run_metadata)
    select ua, ag, x, x, 'completed', 'scheduled', '{"task":"daily","summary":{"capped":true}}'
      from (values (date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' + interval '1 minute'),
                   (date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '1 day' + interval '10 hours')) v(x);
    -- and a capped weekly run (not daily) the day before: still no item
    insert into public.agent_runs (user_id, agent_id, started_at, finished_at, status, trigger_type, run_metadata)
      values (ua, ag, date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days' + interval '10 hours',
              date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days' + interval '10 hours',
              'completed', 'scheduled', '{"task":"weekly","summary":{"capped":true}}');
    d := public.crm_steward_digest(false);
    msg := msg || 'capped2=' || (select count(*) from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health') || ' ';
    -- a capped daily run on the third UTC day: item, capped_3_days, 0 failed runs
    insert into public.agent_runs (user_id, agent_id, started_at, finished_at, status, trigger_type, run_metadata)
      values (ua, ag, date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days' + interval '1 minute',
              date_trunc('day', now() at time zone 'UTC') at time zone 'UTC' - interval '2 days' + interval '1 minute',
              'completed', 'scheduled', '{"task":"daily","summary":{"capped":true}}');
    d := public.crm_steward_digest(false);
    msg := msg || 'capped3=' || coalesce((select (e->>'failed_runs') || '/' || (e->>'capped_3_days')
                                           from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health'), 'none');
    reset role;
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := msg || 'error ' || sqlstate || ' ' || sqlerrm; end if;
  end;
  r := r || jsonb_build_object('TC-SB574-7', case
         when msg = 'none=0 old_failed=0 failed=1/true/false capped2=0 capped3=0/true' then 'pass' else 'FAIL: ' || msg end);

  -- ------------------------------------------------ TC-SB574-8: delivery routing (owner): nothing / FYI only / items
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    d := public.crm_steward_digest(false);
    if (d->>'item_count')::int <> 0 or (d->>'fyi_merge_count')::int <> 0 then
      raise exception 'precondition: owner baseline has % items and % FYI merges', d->'item_count', d->'fyi_merge_count';
    end if;
    select count(*) into wi0 from public.work_items where meta->>'issue_type' = 'crm_steward_digest';
    d := public.crm_steward_digest(true);                             -- nothing to send
    select count(*) into wi1 from public.work_items where meta->>'issue_type' = 'crm_steward_digest';
    msg := format('nothing: delivered %s tickets %s->%s; ', d->'delivered', wi0, wi1);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := 'error ' || sqlstate || ' ' || sqlerrm || '; '; end if;
  end;
  begin
    reset role;
    insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
      values (ub, ub, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture');
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    d := public.crm_steward_digest(true);
    select * into wi from public.work_items where id = (d->>'work_item')::uuid;
    msg := msg || format('fyi: %s/%s/%s/%s/%s/%s/%s; ', wi.status, wi.priority, wi.assignee, wi.type, wi.parent_id = epic and wi.project_id = sb,
                         wi.meta->>'flagged_for_jason', wi.title = 'CRM Steward weekly digest: 0 items for Jason (1 FYI merge)');
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := msg || 'fyi error ' || sqlstate || ' ' || sqlerrm || '; '; end if;
  end;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb574', 'crm_steward_decisions', 'qa_suspend');
    d := public.crm_steward_digest(true);
    select * into wi from public.work_items where id = (d->>'work_item')::uuid;
    msg := msg || format('items: %s/%s/%s/%s/%s/%s/%s/%s', wi.status, wi.priority, wi.assignee, wi.type, wi.parent_id = epic and wi.project_id = sb,
                         wi.meta->>'flagged_for_jason', wi.meta->'item_types', wi.ticket_code = d->>'ticket_code' and wi.assigned_agent_id is not null
                         and wi.meta->>'originating_agent' = 'CRM Data Steward' and (wi.meta->>'item_count')::int = 1
                         and wi.title = 'CRM Steward weekly digest: 1 item for Jason (0 FYI merges)');
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := msg || 'items error ' || sqlstate || ' ' || sqlerrm; end if;
  end;
  r := r || jsonb_build_object('TC-SB574-8', case
         when msg = 'nothing: delivered false tickets 0->0; fyi: todo/low/JARVIS — Master Orchestrator/task/t/false/t; '
                 || 'items: awaiting_jason/medium/JARVIS — Master Orchestrator/task/t/true/{"auto_merge_suspended": 1}/t'
         then 'pass' else 'FAIL: ' || msg end);

  -- ------------------------------------------------ TC-SB574-9: at most one delivered digest per 6 days
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb574', 'crm_steward_decisions', 'qa_suspend');
    d := public.crm_steward_digest(true);
    d2 := public.crm_steward_digest(true);
    res := public.crm_steward_digest(false);                          -- the preview is never skipped
    select count(*) into n from public.work_items where meta->>'issue_type' = 'crm_steward_digest';
    msg := format('second skipped %s preview items %s tickets %s; ', d2->'skipped', res->'item_count', n);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := 'error ' || sqlstate || ' ' || sqlerrm || '; '; end if;
  end;
  foreach st in array array['5 days 23 hours', '6 days 1 hour'] loop
    begin
      reset role;
      insert into public.work_items (project_id, user_id, type, title, status, priority, meta, created_at)
        values (sb, ub, 'task', 'QA fixture: earlier digest', 'todo', 'low',
                '{"issue_type":"crm_steward_digest","qa_fixture":true}'::jsonb, now() - st::interval);
      perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
      set local role authenticated;
      insert into public.crm_steward_decisions (decision, rule, entity_type, reason_code) values ('suspend', 'qa_sb574', 'crm_steward_decisions', 'qa_suspend');
      d := public.crm_steward_digest(true);
      msg := msg || format('%s ago: skipped %s delivered %s; ', st, coalesce(d->>'skipped', 'false'), coalesce(d->>'delivered', 'false'));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then msg := msg || st || ' error ' || sqlstate || ' ' || sqlerrm || '; '; end if;
    end;
  end loop;
  r := r || jsonb_build_object('TC-SB574-9', case
         when msg = 'second skipped true preview items 1 tickets 1; 5 days 23 hours ago: skipped true delivered false; 6 days 1 hour ago: skipped false delivered true; '
         then 'pass' else 'FAIL: ' || msg end);

  -- ------------------------------------------------ TC-SB574-10: 50-line cap per section; no PII in the delivered ticket
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    for i in 1 .. 55 loop
      insert into public.crm_people (display_name, given_name, family_name) values (format('Zq Wexcombe%s', i), 'Zq', format('Wexcombe%s', i)) returning id into a1;
      insert into public.crm_people (display_name, given_name, family_name) values (format('Zq Ruddleton%s', i), 'Zq', format('Ruddleton%s', i)) returning id into b1;
      insert into public.crm_contact_points (person_id, kind, value) values (a1, 'handle', format('@zqsb574cap%s', i)), (b1, 'handle', format('@zqsb574cap%s', i));
    end loop;
    reset role;
    insert into public.crm_steward_decisions (user_id, actor_id, decision, rule, entity_type, entity_id, reason_code)
    select ub, ub, 'auto_merge', 'auto_merge_contact', 'crm_people', gen_random_uuid(), 'qa_fixture' from generate_series(1, 52);
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    d := public.crm_steward_digest(true);
    select * into wi from public.work_items where id = (d->>'work_item')::uuid;
    reset role;
    txt := lower(coalesce(wi.title, '') || ' ' || coalesce(wi.description, '') || ' ' || coalesce(wi.meta::text, ''));
    select count(*) into n from regexp_matches(wi.description, '^- \*\*strong_pair_not_merged\*\*', 'gn');
    select count(*) into m from regexp_matches(wi.description, '^- `[0-9a-f-]{36}` · auto_merge_contact · undo handle', 'gn');
    select count(*) into k from public.crm_people p where p.user_id = ub and length(btrim(p.display_name)) >= 4 and strpos(txt, lower(btrim(p.display_name))) > 0;
    select count(*) into i from public.crm_contact_points cp where cp.user_id = ub and length(btrim(cp.value)) >= 5 and strpos(txt, lower(btrim(cp.value))) > 0;
    r := r || jsonb_build_object('TC-SB574-10', case
           when (d->>'item_count')::int = 55 and (d->>'fyi_merge_count')::int = 52 and (d->>'over_target')::boolean
            and n = 50 and wi.description like '%- … and 5 more%' and m = 50 and wi.description like '%- … and 2 more%'
            and (wi.meta->>'item_count')::int = 55 and (wi.meta->>'over_target')::boolean and wi.status = 'awaiting_jason'
            and k = 0 and i = 0 and txt !~ '@|zq\.example|wexcombe|ruddleton'
           then 'pass' else format('FAIL: items %s fyi %s; item lines %s fyi lines %s; more-lines %s/%s; names %s contact values %s; raw text %s',
                                   d->'item_count', d->'fyi_merge_count', n, m, wi.description like '%- … and 5 more%', wi.description like '%- … and 2 more%',
                                   k, i, txt ~ '@|zq\.example|wexcombe|ruddleton') end);
    r := r || jsonb_build_object('TC-SB574-10.evidence', format('ticket %s (rolled back): 55 items -> 50 lines + "and 5 more"; 52 FYI -> 50 lines + "and 2 more"; PII scan names %s contact values %s',
                                   wi.ticket_code, k, i));
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB574-10', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
  end;

  -- ------------------------------------------------ TC-SB574-11: a failed run escalates once; de-duplicated while open; again after done
  begin
    select c.command into cmd from cron.job c where c.jobname = 'crm-steward-daily';
    reset role;
    update public.agents set automation_enabled = true where id = aid and status = 'active';
    revoke execute on function public.crm_steward_run(boolean, integer) from authenticated;
    select count(*) into wi0 from public.work_items where meta->>'issue_type' = 'crm_steward_run_failed';
    select error_count into ec0 from public.agents where id = aid;
    execute cmd;                                                       -- the daily cron job fails
    reset role;
    select * into wi from public.work_items where meta->>'issue_type' = 'crm_steward_run_failed' order by created_at desc limit 1;
    select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    res := public.crm_steward_scheduled('daily');                      -- second failure while the ticket is open
    d := public.crm_steward_digest(false);
    reset role;
    select count(*) into wi1 from public.work_items where meta->>'issue_type' = 'crm_steward_run_failed';
    select error_count into ec1 from public.agents where id = aid;
    msg := format('first: %s/%s/%s/%s/%s/%s/%s/%s; second: status %s escalation %s run %s tickets %s->%s errors %s->%s health %s; ',
                  wi.type, wi.status, wi.priority, wi.assignee, wi.parent_id = epic and wi.project_id = sb,
                  wi.meta->>'run_id' = ar.id::text and ar.status = 'failed', wi.meta->>'task', wi.meta->>'error_code',
                  res->>'status', coalesce(res->>'escalation', 'null'), res->>'run_id' is not null, wi0, wi1, ec0, ec1,
                  (select e->>'failed_runs' from jsonb_array_elements(d->'items') e where e->>'type' = 'steward_health'));
    -- the open escalation is closed (simulated): the next failure opens a new one
    update public.work_items set status = 'done',
           meta = meta || '{"approval_gate_exempt":true,"review_gate_exempt":true,"qa_gate_exempt":true}'::jsonb
     where id = wi.id;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    res2 := public.crm_steward_scheduled('daily');
    reset role;
    select count(*) into n from public.work_items where meta->>'issue_type' = 'crm_steward_run_failed';
    msg := msg || format('after done: escalation %s tickets %s', res2->>'escalation' ~ '^SB-[0-9]+$', n);
    txt := lower(coalesce(wi.title, '') || ' ' || coalesce(wi.description, '') || ' ' || coalesce(wi.meta::text, ''));
    r := r || jsonb_build_object('TC-SB574-11', case
           when msg = format('first: bug/escalated/high/JARVIS — Master Orchestrator/t/t/daily/42501; second: status failed escalation null run t tickets %s->%s errors %s->%s health 2; after done: escalation t tickets %s',
                             wi0, wi0 + 1, ec0, coalesce(ec0, 0) + 2, wi0 + 2)
            and txt !~ '@|permission denied'
           then 'pass' else 'FAIL: ' || msg end);
    r := r || jsonb_build_object('TC-SB574-11.evidence', format('escalated ticket %s (rolled back); %s', wi.ticket_code, msg));
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB574-11', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
  end;

  -- ------------------------------------------------ TC-SB574-12: the escalation never breaks the run log, even if the ticket insert fails
  begin
    reset role;
    update public.agents set automation_enabled = true where id = aid and status = 'active';
    revoke execute on function public.crm_steward_run(boolean, integer) from authenticated;
    revoke insert on public.work_items from authenticated;
    select count(*) into runs0 from public.agent_runs where agent_id = aid;
    select count(*) into wi0 from public.work_items;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    st := 'no error';
    begin
      res := public.crm_steward_scheduled('daily');
    exception when others then st := sqlstate || ' ' || sqlerrm; end;
    reset role;
    select count(*) into runs1 from public.agent_runs where agent_id = aid;
    select count(*) into wi1 from public.work_items;
    select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
    r := r || jsonb_build_object('TC-SB574-12', case
           when st = 'no error' and res->>'status' = 'failed' and res->'escalation' = 'null'::jsonb and runs1 = runs0 + 1
            and ar.status = 'failed' and ar.id::text = res->>'run_id' and wi1 = wi0
           then 'pass' else format('FAIL: call %s status %s escalation %s runs %s->%s tickets %s->%s', st, res->>'status', res->'escalation', runs0, runs1, wi0, wi1) end);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB574-12', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
  end;

  -- ------------------------------------------------ TC-SB574-13: weekly cron command: no-op while off; digest when on; a weekly failure escalates
  begin
    select c.command into cmd from cron.job c where c.jobname = 'crm-steward-weekly';
    reset role;
    select count(*) into runs0 from public.agent_runs where agent_id = aid;
    select count(*) into wi0 from public.work_items;
    select count(*) into k from public.crm_steward_decisions;
    execute cmd;                                                       -- automation off
    reset role;
    msg := format('off: runs %s tickets %s decisions %s; ', (select count(*) from public.agent_runs where agent_id = aid) - runs0,
                  (select count(*) from public.work_items) - wi0, (select count(*) from public.crm_steward_decisions) - k);
    update public.agents set automation_enabled = true where id = aid and status = 'active';
    execute cmd;                                                       -- automation on
    reset role;
    select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
    msg := msg || format('on: %s/%s/%s/%s/%s/%s; ', ar.status, ar.run_metadata->>'task', ar.run_metadata->'summary' ? 'digest',
                         (ar.run_metadata->'summary'->'digest') ? 'items' or (ar.run_metadata->'summary'->'digest') ? 'fyi_merges',
                         ar.result_summary ~ '^qa sample \d+ \(merges \d+\) (SB-\d+|no ticket); digest \d+ items, \d+ FYI merges, (SB-\d+|nothing to send)$',
                         ar.duration_ms is not null);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := 'error ' || sqlstate || ' ' || sqlerrm || '; '; end if;
  end;
  begin
    reset role;
    update public.agents set automation_enabled = true where id = aid and status = 'active';
    revoke execute on function public.crm_steward_digest(boolean) from authenticated;
    select count(*) into k from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample';
    execute cmd;
    reset role;
    select * into ar from public.agent_runs where agent_id = aid order by created_at desc, started_at desc limit 1;
    select * into wi from public.work_items where meta->>'issue_type' = 'crm_steward_run_failed' order by created_at desc limit 1;
    msg := msg || format('weekly failure: %s/%s/%s, escalation %s/%s, qa tickets kept %s',
                         ar.status, ar.run_metadata->>'task', ar.error_code, wi.status, wi.meta->>'task',
                         (select count(*) from public.work_items where meta->>'issue_type' = 'crm_steward_qa_sample') - k);
    raise exception '%', rb;
  exception when others then
    if sqlerrm <> rb then msg := msg || 'error ' || sqlstate || ' ' || sqlerrm; end if;
  end;
  r := r || jsonb_build_object('TC-SB574-13', case
         when msg = 'off: runs 0 tickets 0 decisions 0; on: completed/weekly/t/f/t/t; weekly failure: failed/weekly/42501, escalation escalated/weekly, qa tickets kept 0'
         then 'pass' else 'FAIL: ' || msg end);

  -- ------------------------------------------------ TC-SB574-14: posture, bodies, no-auth/anon, cron, skill content
  begin
    reset role;
    select count(*) into n from pg_proc p
     where p.oid in ('public.crm_steward_digest(boolean)'::regprocedure, 'public.crm_steward_scheduled(text)'::regprocedure)
       and not p.prosecdef and p.proconfig @> array['search_path=""']
       and not has_function_privilege('anon', p.oid, 'execute') and not has_function_privilege('public', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute');
    select count(*) into m from pg_proc p
     where (p.oid = 'public.crm_steward_digest(boolean)'::regprocedure and md5(p.prosrc) = md5_digest)
        or (p.oid = 'public.crm_steward_scheduled(text)'::regprocedure and md5(p.prosrc) = md5_scheduled and p.prosrc !~ 'duration_ms');
    msg := '';
    begin
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim.sub', '', true);
      set local role authenticated;
      begin perform public.crm_steward_digest(false); msg := 'noauth:ok'; exception when others then msg := 'noauth:' || sqlstate; end;
      set local role anon;
      begin perform public.crm_steward_digest(false); msg := msg || ' anon:ok'; exception when others then msg := msg || ' anon:' || sqlstate; end;
      reset role;
    end;
    select count(*) into k from cron.job c, regexp_matches(c.command, '(crm_steward_[a-z_]+)', 'g') x where x[1] <> 'crm_steward_scheduled';
    select count(*) into i from public.skills s where s.skill_id = 'crm-data-steward' and md5(s.content) = md5_skill and not s.archived;
    r := r || jsonb_build_object('TC-SB574-14', case
           when n = 2 and m = 2 and msg = 'noauth:42501 anon:42501' and k = 0 and i = 1 then 'pass'
           else format('FAIL: posture %s of 2, bodies %s of 2, [%s], other cron calls %s, skill content md5 ok %s', n, m, msg, k, i) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB574-14', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  reset role;
  if exists (select 1 from public.agents where id = aid and automation_enabled) then
    r := r || jsonb_build_object('GUARD', 'FAIL: automation_enabled left true inside the suite');
  end if;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-STEWARD-DIGEST PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'CRM-STEWARD-DIGEST FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
