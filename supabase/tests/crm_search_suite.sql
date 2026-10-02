-- CRM search / duplicates / merge QA suite: TC-SB467..469 (ADR-CRM-003).
--
-- Same method as the other CRM suites: two signed-in users (A and B) in one
-- transaction that ALWAYS ends by raising, so every row written here is rolled
-- back. Invented names and example.com values only. Run as postgres.
-- Pass = the raised message starts with "CRM-SEARCH PASS".
-- No row-removal statements, so it runs unattended through the MCP connector.
-- Performance (TC-SB469-V7, TC-SB468-V6) is a separate file: crm_search_perf.sql.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; b boolean; st text; x record;
  pA uuid; pP uuid; pG uuid; pS1 uuid; pS2 uuid; pPar uuid; pKid uuid; pT uuid;
  pN1 uuid; pN2 uuid; pN3 uuid; pArch uuid; q1 uuid; q2 uuid; q3 uuid;
  pE1 uuid; pE2 uuid; pPh1 uuid; pPh2 uuid; pJ1 uuid; pJ2 uuid; pC1 uuid; pC2 uuid; pM1 uuid; pM2 uuid;
  pX1 uuid; pX2 uuid; pCo1 uuid; pCo2 uuid;
  pK uuid; pM uuid; pO uuid; pB uuid;
  oG uuid; oAcme uuid; oKeep uuid; tg uuid; g1 uuid; g2 uuid; i1 uuid; i2 uuid; fM uuid; dis uuid; v_log uuid;
  tSib uuid; tPar uuid; tFr uuid;
  cap timestamptz;
  before_people int; before_cp int; before_audit int; before_upd timestamptz;
  fails int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into tSib from public.crm_relationship_types where user_id is null and code = 'sibling';
  select id into tPar from public.crm_relationship_types where user_id is null and code = 'parent';
  select id into tFr  from public.crm_relationship_types where user_id is null and code = 'friend';

  -- =============================================================== SB-469 search
  insert into public.crm_people (display_name) values ('Avery Testperson') returning id into pA;
  select count(*) into n from public.crm_search('  avery   TESTPERSON ') s where s.person_id = pA and s.matched_on = 'name';
  select count(*) into m from public.crm_search('avery testprson') s where s.person_id = pA;
  r := r || jsonb_build_object('TC-SB469-V1', case when n = 1 and m = 1 then 'pass' else format('FAIL: %s / %s', n, m) end);

  insert into public.crm_people (display_name) values ('Rowan Quillfeather') returning id into pP;
  insert into public.crm_contact_points (person_id, kind, value) values (pP, 'email', 'pat@example.com'), (pP, 'phone', '+15550100000');
  select count(*) into n from public.crm_search(' PAT@example.com ') s where s.person_id = pP and s.matched_on = 'email';
  select count(*) into m from public.crm_search('+1 (555) 010-0000') s where s.person_id = pP and s.matched_on = 'phone';
  select count(*) into k from public.crm_search('pat@ex') s where s.person_id = pP and s.matched_on = 'email';
  r := r || jsonb_build_object('TC-SB469-V2', case when n = 1 and m = 1 and k = 1 then 'pass' else format('FAIL: email %s phone %s prefix %s', n, m, k) end);

  insert into public.crm_people (display_name) values ('Marisol Vantongeren') returning id into pG;
  insert into public.crm_organizations (name, org_type) values ('Globex Industries', 'company') returning id into oG;
  insert into public.crm_affiliations (person_id, organization_id, role_title) values (pG, oG, 'Engineer');
  select count(*) into n from public.crm_search('globex') s where s.person_id = pG and s.matched_on = 'organization';
  r := r || jsonb_build_object('TC-SB469-V3.organization', case when n = 1 then 'pass' else format('FAIL: %s', n) end);
  insert into public.crm_people (display_name) values ('Ingrid Holmqvist') returning id into pS1;
  insert into public.crm_people (display_name) values ('Torvald Holmqvist') returning id into pS2;
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pS1, pS2, tSib);
  select count(*) into n from public.crm_search('sibling') s where s.person_id in (pS1, pS2) and s.matched_on = 'relationship';
  r := r || jsonb_build_object('TC-SB469-V3.sibling', case when n = 2 then 'pass' else format('FAIL: %s', n) end);
  insert into public.crm_people (display_name) values ('Octavia Brennerman') returning id into pPar;
  insert into public.crm_people (display_name) values ('Felix Brennerman') returning id into pKid;
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pPar, pKid, tPar);
  select count(*) filter (where s.person_id = pKid), count(*) filter (where s.person_id = pPar)
    into n, m from public.crm_search('child') s where s.matched_on = 'relationship';
  select count(*) filter (where s.person_id = pPar), count(*) filter (where s.person_id = pKid)
    into k, fails from public.crm_search('parent') s where s.matched_on = 'relationship';
  r := r || jsonb_build_object('TC-SB469-V3.direction', case when n = 1 and m = 0 and k = 1 and fails = 0 then 'pass'
                                                            else format('FAIL: child->kid %s par %s; parent->par %s kid %s', n, m, k, fails) end);
  insert into public.crm_people (display_name) values ('Hollis Wexford') returning id into pT;
  insert into public.crm_tags (name) values ('golfbuddy') returning id into tg;
  insert into public.crm_entity_tags (tag_id, person_id) values (tg, pT);
  select count(*) into n from public.crm_search('golfbuddy') s where s.person_id = pT and s.matched_on = 'tag';
  r := r || jsonb_build_object('TC-SB469-V3.tag', case when n = 1 then 'pass' else format('FAIL: %s', n) end);

  insert into public.crm_people (display_name) values ('Nadia Pellworth') returning id into pN1;
  insert into public.crm_people (display_name) values ('Corwin Ashbury') returning id into pN2;
  insert into public.crm_people (display_name) values ('Lucinda Farrow') returning id into pN3;
  insert into public.crm_facts (person_id, fact_type, value) values (pN1, 'hobby', 'loves sourdough baking');
  insert into public.crm_interactions (interaction_type, summary, sensitivity) values ('call', 'talked about sourdough starters', 'private') returning id into i1;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i1, pN2);
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pN3, 'note', 'sourdough secret recipe', 'sensitive');
  select count(*) filter (where s.person_id in (pN1, pN2) and s.matched_on = 'note'), count(*) filter (where s.person_id = pN3)
    into n, m from public.crm_search('sourdough') s;
  r := r || jsonb_build_object('TC-SB469-V4', case when n = 2 and m = 0 then 'pass' else format('FAIL: found %s, restricted %s', n, m) end);

  insert into public.crm_people (display_name, archived) values ('Zephyrine Archivewell', true) returning id into pArch;
  select count(*) into n from public.crm_search('zephyrine');
  insert into public.crm_people (display_name) values ('Quill Alpha') returning id into q1;
  insert into public.crm_people (display_name) values ('Quill Beta') returning id into q2;
  insert into public.crm_people (display_name) values ('Quill Gamma') returning id into q3;
  select count(*) into m from public.crm_search('quill', 2);
  r := r || jsonb_build_object('TC-SB469-V5', case when n = 0 and m = 2 then 'pass' else format('FAIL: archived %s, limited %s', n, m) end);

  -- =============================================================== SB-468 duplicates
  insert into public.crm_people (display_name) values ('Robin Oakhurst') returning id into pE1;
  insert into public.crm_people (display_name) values ('Wren Balderston') returning id into pE2;
  insert into public.crm_contact_points (person_id, kind, value) values (pE1, 'email', 'twin@example.com'), (pE2, 'email', 'Twin@Example.com');
  insert into public.crm_people (display_name) values ('Ellery Sandoval') returning id into pPh1;
  insert into public.crm_people (display_name) values ('Juno Ferraday') returning id into pPh2;
  insert into public.crm_contact_points (person_id, kind, value) values (pPh1, 'phone', '+1 (555) 222-3333'), (pPh2, 'phone', '+15552223333');
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pE1, pE2) and c.person_b = greatest(pE1, pE2) and c.strength = 'strong'
     and 'same email twin@example.com' = any(c.reasons);
  select count(*) into m from public.crm_duplicate_candidates() c
   where c.person_a = least(pPh1, pPh2) and c.person_b = greatest(pPh1, pPh2) and c.strength = 'strong'
     and 'same phone +15552223333' = any(c.reasons);
  r := r || jsonb_build_object('TC-SB468-V1', case when n = 1 and m = 1 then 'pass' else format('FAIL: email %s phone %s', n, m) end);

  insert into public.crm_organizations (name) values ('Acme Holdings') returning id into oAcme;
  insert into public.crm_people (display_name) values ('Jonathan Marlowe') returning id into pJ1;
  insert into public.crm_people (display_name) values ('Jonathon Marlowe') returning id into pJ2;
  insert into public.crm_affiliations (person_id, organization_id) values (pJ1, oAcme), (pJ2, oAcme);
  insert into public.crm_people (display_name) values ('Katherine Holloway') returning id into pC1;
  insert into public.crm_people (display_name) values ('Catherine Holloway') returning id into pC2;
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pC1, 'birthday', 4, 9, 1984), (pC2, 'birthday', 4, 9, null);
  insert into public.crm_people (display_name) values ('Morgan Leclerc') returning id into pM1;
  insert into public.crm_people (display_name) values ('morgan  leclerc') returning id into pM2;
  insert into public.crm_people (display_name) values ('Alexandra Pembrooke') returning id into pX1;
  insert into public.crm_people (display_name) values ('Alexandria Pembrooke') returning id into pX2;
  insert into public.crm_people (display_name) values ('Priya Ramanathan') returning id into pCo1;
  insert into public.crm_people (display_name) values ('Tobias Kerrigan') returning id into pCo2;
  insert into public.crm_affiliations (person_id, organization_id) values (pCo1, oAcme), (pCo2, oAcme);
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pJ1, pJ2) and c.person_b = greatest(pJ1, pJ2) and c.strength = 'possible' and 'both at Acme Holdings' = any(c.reasons);
  r := r || jsonb_build_object('TC-SB468-V2.shared_org', case when n = 1 then 'pass' else format('FAIL: %s (sim %s)', n,
        (select extensions.similarity('jonathan marlowe', 'jonathon marlowe'))) end);
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pC1, pC2) and c.person_b = greatest(pC1, pC2) and 'same birthday' = any(c.reasons);
  r := r || jsonb_build_object('TC-SB468-V2.birthday', case when n = 1 then 'pass' else format('FAIL: %s (sim %s)', n,
        (select extensions.similarity('katherine holloway', 'catherine holloway'))) end);
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pM1, pM2) and c.person_b = greatest(pM1, pM2) and 'same name' = any(c.reasons);
  r := r || jsonb_build_object('TC-SB468-V2.same_name', case when n = 1 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pX1, pX2) and c.person_b = greatest(pX1, pX2);
  b := (select extensions.similarity('alexandra pembrooke', 'alexandria pembrooke')) >= 0.8;
  r := r || jsonb_build_object('TC-SB468-V2.no_context_rule', case when (n = 1) = b then 'pass' else format('FAIL: listed=%s, sim>=0.8=%s', n, b) end);
  select count(*) into n from public.crm_duplicate_candidates() c
   where c.person_a = least(pCo1, pCo2) and c.person_b = greatest(pCo1, pCo2);
  r := r || jsonb_build_object('TC-SB468-V2.colleagues_not_listed', case when n = 0 then 'pass' else 'FAIL' end);

  -- V4 non-destructive: nothing changes when candidates are computed
  select count(*), max(updated_at) into before_people, before_upd from public.crm_people;
  select count(*) into before_cp from public.crm_contact_points;
  select count(*) into before_audit from public.crm_audit_log;
  perform * from public.crm_duplicate_candidates(1000);
  select count(*) into n from public.crm_people;
  select count(*) into m from public.crm_contact_points;
  select count(*) into k from public.crm_audit_log;
  r := r || jsonb_build_object('TC-SB468-V4.no_change', case when n = before_people and m = before_cp and k = before_audit
                                    and (select max(updated_at) from public.crm_people) = before_upd then 'pass' else 'FAIL' end);

  -- V3 dismissal
  dis := public.crm_dismiss_duplicate(pE2, pE1);
  select count(*) into n from public.crm_duplicate_candidates() c where c.person_a = least(pE1, pE2) and c.person_b = greatest(pE1, pE2);
  select person_a = least(pE1, pE2) and person_b = greatest(pE1, pE2) into b from public.crm_duplicate_dismissals where id = dis;
  r := r || jsonb_build_object('TC-SB468-V3.dismissed', case when n = 0 and b then 'pass' else format('FAIL: listed %s, canonical %s', n, b) end);
  begin
    perform public.crm_dismiss_duplicate(pE1, pE2);
    r := r || jsonb_build_object('TC-SB468-V3.twice', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB468-V3.twice', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  update public.crm_duplicate_dismissals set archived = true where id = dis;
  select count(*) into n from public.crm_duplicate_candidates() c where c.person_a = least(pE1, pE2) and c.person_b = greatest(pE1, pE2);
  r := r || jsonb_build_object('TC-SB468-V3.undismiss', case when n = 1 then 'pass' else format('FAIL: %s', n) end);

  -- =============================================================== SB-467 merge
  insert into public.crm_people (display_name, pronouns) values ('Dana Keepsworth', 'she/her') returning id into pK;
  insert into public.crm_people (display_name, given_name, pronouns, contact_cadence_days) values ('Dana Mergeworth', 'Dana', 'they/them', 45) returning id into pM;
  insert into public.crm_people (display_name) values ('Otis Fairweather') returning id into pO;
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pK, 'email', 'dana@example.com', true);
  insert into public.crm_contact_points (person_id, kind, value) values (pM, 'email', 'dana@example.com');
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pM, 'email', 'dana.work@example.com', true);
  insert into public.crm_addresses (person_id, city) values (pM, 'Exampleton');
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pM, pO, tFr);
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pM, pK, tSib);
  insert into public.crm_organizations (name) values ('Keepsake Ltd') returning id into oKeep;
  insert into public.crm_affiliations (person_id, organization_id) values (pM, oKeep);
  insert into public.crm_groups (name) values ('Book Club') returning id into g1;
  insert into public.crm_groups (name) values ('Running Group') returning id into g2;
  insert into public.crm_group_members (group_id, person_id) values (g1, pK), (g1, pM), (g2, pM);
  insert into public.crm_entity_tags (tag_id, person_id) values (tg, pM);
  insert into public.crm_important_dates (person_id, kind, month, day) values (pM, 'birthday', 7, 4);
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
    values (pM, 'employer_guess', 'probably Keepsake', 'agent', 'qa_agent', 0.50) returning id into fM;
  select captured_at into cap from public.crm_facts where id = fM;
  insert into public.crm_interactions (interaction_type, occurred_at) values ('meeting', now() - interval '3 days') returning id into i1;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i1, pK), (i1, pM);
  insert into public.crm_interactions (interaction_type, occurred_at) values ('call', now() - interval '1 day') returning id into i2;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i2, pM);
  insert into public.crm_actions (title, person_id) values ('Send the merge photos', pM);

  -- V4 invalid calls
  begin perform public.crm_merge_people(pK, pM, null); r := r || jsonb_build_object('TC-SB467-V4.no_reason', 'FAIL: merged');
  exception when others then r := r || jsonb_build_object('TC-SB467-V4.no_reason', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end); end;
  begin perform public.crm_merge_people(pK, pM, 'They are the same'); r := r || jsonb_build_object('TC-SB467-V4.prose_reason', 'FAIL: merged');
  exception when others then r := r || jsonb_build_object('TC-SB467-V4.prose_reason', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end); end;
  begin perform public.crm_merge_people(pK, pK, 'same_person_confirmed'); r := r || jsonb_build_object('TC-SB467-V4.same_id', 'FAIL: merged');
  exception when others then r := r || jsonb_build_object('TC-SB467-V4.same_id', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end); end;
  begin perform public.crm_merge_people(pK, pArch, 'same_person_confirmed'); r := r || jsonb_build_object('TC-SB467-V4.archived', 'FAIL: merged');
  exception when others then r := r || jsonb_build_object('TC-SB467-V4.archived', case when sqlstate = 'P0002' then 'pass' else 'FAIL: ' || sqlstate end); end;

  v_log := public.crm_merge_people(pK, pM, 'same_person_confirmed');

  -- V1 references moved
  select count(*) into n from public.crm_contact_points where person_id = pK and not archived;
  select count(*) into m from public.crm_group_members where person_id = pK and not archived;
  select count(*) into k from public.crm_interaction_participants where person_id = pK and not archived;
  r := r || jsonb_build_object('TC-SB467-V1.moved_counts', case when n = 2 and m = 2 and k = 2 then 'pass' else format('FAIL: cp %s groups %s parts %s', n, m, k) end);
  select (select count(*) from public.crm_addresses where person_id = pK)
       + (select count(*) from public.crm_affiliations where person_id = pK)
       + (select count(*) from public.crm_entity_tags where person_id = pK)
       + (select count(*) from public.crm_important_dates where person_id = pK)
       + (select count(*) from public.crm_facts where person_id = pK)
       + (select count(*) from public.crm_actions where person_id = pK)
       + (select count(*) from public.crm_person_relationships where (person_id = pK or related_person_id = pK) and not archived)
    into n;
  r := r || jsonb_build_object('TC-SB467-V1.other_tables', case when n = 7 then 'pass' else format('FAIL: %s of 7', n) end);
  select (select count(*) from public.crm_contact_points where person_id = pM and not archived)
       + (select count(*) from public.crm_addresses where person_id = pM and not archived)
       + (select count(*) from public.crm_person_relationships where (person_id = pM or related_person_id = pM) and not archived)
       + (select count(*) from public.crm_group_members where person_id = pM and not archived)
       + (select count(*) from public.crm_interaction_participants where person_id = pM and not archived)
       + (select count(*) from public.crm_actions where person_id = pM and not archived)
    into n;
  select (select sum(value::int) from jsonb_each_text(moved)) into m from public.crm_merge_log where id = v_log;
  r := r || jsonb_build_object('TC-SB467-V1.nothing_live_left', case when n = 0 and m = 10 then 'pass' else format('FAIL: live left %s, logged moves %s', n, m) end);

  -- V2 conflicts kept as archived history
  select (select sum(value::int) from jsonb_each_text(kept_on_merged)) into n from public.crm_merge_log where id = v_log;
  select is_preferred into b from public.crm_contact_points where value = 'dana.work@example.com';
  select count(*) into m from public.crm_person_relationships where relationship_type_id = tSib and archived and (person_id = pM or related_person_id = pM);
  select count(*) into k from public.crm_contact_points where person_id = pK and is_preferred and kind = 'email';
  r := r || jsonb_build_object('TC-SB467-V2', case when n = 4 and b = false and m = 1 and k = 1 then 'pass'
                                                   else format('FAIL: kept %s, work preferred %s, self-link archived %s, preferred on keep %s', n, b, m, k) end);

  -- V3 traceable
  select archived and merged_into_id = pK and merged_at is not null into b from public.crm_people where id = pM;
  select count(*) into n from public.crm_merge_log where id = v_log and merged_display_name = 'Dana Mergeworth' and merged_person_id = pM and kept_person_id = pK;
  select count(*) into m from public.crm_facts where id = fM and person_id = pK and source_type = 'agent' and source_ref = 'qa_agent' and confidence = 0.50 and captured_at = cap and not is_confirmed;
  select count(*) into k from public.crm_people where id = pK and given_name = 'Dana' and pronouns = 'she/her' and contact_cadence_days = 45;
  r := r || jsonb_build_object('TC-SB467-V3', case when b and n = 1 and m = 1 and k = 1 then 'pass' else format('FAIL: retired %s, log %s, provenance %s, blanks %s', b, n, m, k) end);
  select count(*) into n from public.crm_search('dana mergeworth') s where s.person_id = pM;
  r := r || jsonb_build_object('TC-SB469-V5.merged_excluded', case when n = 0 then 'pass' else 'FAIL' end);

  -- V4 audited, log append-only
  select count(*) into n from public.crm_audit_log where action = 'merge' and entity_id = pK and reason_code = 'same_person_confirmed' and entity_count = 10;
  r := r || jsonb_build_object('TC-SB467-V4.audited', case when n = 1 then 'pass' else format('FAIL: %s', n) end);
  begin
    update public.crm_merge_log set reason_code = 'tampered' where id = v_log;
    get diagnostics n = row_count;
    r := r || jsonb_build_object('TC-SB467-V4.log_owner_update', case when n = 0 then 'pass' else 'FAIL: updated' end);
  exception when others then
    r := r || jsonb_build_object('TC-SB467-V4.log_owner_update', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- =============================================================== as user B
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  insert into public.crm_people (display_name) values ('Bea Testperson') returning id into pB;
  select count(*) into n from public.crm_search('avery');
  select count(*) into m from public.crm_search('pat@example.com');
  select count(*) into k from public.crm_search('golfbuddy');
  r := r || jsonb_build_object('TC-SB469-V6.other_user', case when n = 0 and m = 0 and k = 0 then 'pass' else format('FAIL: %s/%s/%s', n, m, k) end);
  select count(*) into n from public.crm_duplicate_candidates(1000) c where c.person_a in (pE1, pE2, pPh1, pPh2, pJ1, pJ2) or c.person_b in (pE1, pE2, pPh1, pPh2, pJ1, pJ2);
  r := r || jsonb_build_object('TC-SB468-V5.list', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
  begin
    perform public.crm_dismiss_duplicate(pJ1, pJ2);
    r := r || jsonb_build_object('TC-SB468-V5.dismiss', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB468-V5.dismiss', case when sqlstate in ('23503', '42501') then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    perform public.crm_merge_people(pA, pP, 'same_person_confirmed');
    r := r || jsonb_build_object('TC-SB467-V5.merge', 'FAIL: merged');
  exception when others then
    r := r || jsonb_build_object('TC-SB467-V5.merge', case when sqlstate = 'P0002' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_merge_log where user_id = ua;
  r := r || jsonb_build_object('TC-SB467-V5.log', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- =============================================================== no session, then catalog as postgres
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  select count(*) into n from public.crm_search('avery');
  select count(*) into m from public.crm_duplicate_candidates();
  r := r || jsonb_build_object('TC-SB469-V6.no_session', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s / %s', n, m) end);
  begin
    update public.crm_merge_log set reason_code = 'tampered' where user_id = ua;
    r := r || jsonb_build_object('TC-SB467-V4.log_postgres_update', 'FAIL: allowed');
  exception when others then
    r := r || jsonb_build_object('TC-SB467-V4.log_postgres_update', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from cron.job where command ~* 'crm_merge|merged_into';
  select count(*) into m from pg_trigger t join pg_proc p on p.oid = t.tgfoid
   where t.tgrelid::regclass::text like 'crm\_%' and p.prosrc ~* 'crm_merge_people|merged_into_id\s*=';
  r := r || jsonb_build_object('TC-SB468-V4.no_auto_merge', case when n = 0 and m = 0
                                    and (select provolatile from pg_proc where oid = 'public.crm_duplicate_candidates(integer)'::regprocedure) = 's'
                                    then 'pass' else format('FAIL: cron %s, triggers %s', n, m) end);
  begin
    perform public.crm_assert_owned_table('public.crm_duplicate_dismissals');
    r := r || jsonb_build_object('catalog.owned.crm_duplicate_dismissals', 'pass');
  exception when others then
    r := r || jsonb_build_object('catalog.owned.crm_duplicate_dismissals', 'FAIL: ' || sqlerrm);
  end;
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname like 'crm\_%' and c.relkind in ('r','v')
     and exists (select 1 from aclexplode(c.relacl) a where a.grantee in (0, 'anon'::regrole::oid));
  select count(*) into m from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and has_function_privilege('anon', p.oid, 'execute');
  r := r || jsonb_build_object('catalog.anon', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s rel, %s fn', n, m) end);
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid
                       and (i.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  r := r || jsonb_build_object('catalog.fk_indexed', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from public.crm_audit_log a
   where a.user_id in (ua, ub) and to_jsonb(a)::text ~* '(example\.com|sourdough|mergeworth|keepsworth)';
  r := r || jsonb_build_object('catalog.audit_no_content', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-SEARCH PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-SEARCH FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;
