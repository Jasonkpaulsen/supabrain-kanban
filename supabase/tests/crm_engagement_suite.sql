-- CRM engagement QA suite: TC-SB458..460 (ADR-CRM-002).
--
-- Same method as crm_suite.sql: two signed-in users (A and B) in one transaction
-- that ALWAYS ends by raising, so every row written here is rolled back. Invented
-- names and example.com values only. Run as postgres (SQL editor or MCP).
-- Pass = the raised message starts with "CRM-ENGAGEMENT PASS".
--
-- Deliberately one block with no row-removal statements: removal auditing is the
-- shared owned-table standard, already proven by crm_suite.sql part 2, and is
-- checked here through the catalog (crm_assert_owned_table). Keeping such
-- statements out lets this run unattended through the MCP connector.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; k int;
  b boolean; st text; d date; x record;
  t text;
  pA uuid; pB2 uuid; pC uuid; pS uuid; pF uuid; pQ uuid; pL uuid; pO uuid; pN uuid; pV uuid; pX uuid;
  pD uuid; pE uuid; pBo uuid; o1 uuid;
  iMeet uuid; iImp uuid; iCall uuid; iSens uuid; iArch uuid; iEmail uuid; iMsg uuid; iTmp uuid;
  aDone uuid; aF uuid; fx uuid;
  types text[] := array['call','meeting','email','message','meal','event','gift','introduction','note'];
  fails int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;

  insert into public.crm_people (display_name) values ('Avery Testperson') returning id into pA;
  insert into public.crm_people (display_name) values ('Blake Testperson') returning id into pB2;
  insert into public.crm_people (display_name) values ('Casey Testperson') returning id into pC;
  insert into public.crm_people (display_name) values ('Sam Testperson')   returning id into pS;
  insert into public.crm_people (display_name) values ('Frankie Testperson') returning id into pF;
  insert into public.crm_people (display_name) values ('Quinn Testperson') returning id into pQ;
  insert into public.crm_people (display_name) values ('Lee Testperson')   returning id into pL;
  insert into public.crm_organizations (name, org_type) values ('Example Corp', 'company') returning id into o1;

  -- =============================================================== SB-460
  -- V1: every common type
  foreach t in array types loop
    insert into public.crm_interactions (interaction_type, occurred_at) values (t, now() - interval '100 days') returning id into iTmp;
    insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pA);
  end loop;
  select count(distinct i.interaction_type) into n from public.crm_interactions i
    join public.crm_interaction_participants ip on ip.interaction_id = i.id where ip.person_id = pA;
  r := r || jsonb_build_object('TC-SB460-V1.types', case when n = 9 then 'pass' else format('FAIL: %s', n) end);
  begin
    insert into public.crm_interactions (interaction_type) values ('telepathy');
    r := r || jsonb_build_object('TC-SB460-V1.unknown_type', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V1.unknown_type', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_interactions (interaction_type, occurred_at, ended_at) values ('meeting', now(), now() - interval '1 hour');
    r := r || jsonb_build_object('TC-SB460-V1.bad_range', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V1.bad_range', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- V2: multi-participant
  insert into public.crm_interactions (interaction_type, title, occurred_at) values ('meeting', 'Planning lunch', now() - interval '50 days') returning id into iMeet;
  insert into public.crm_interaction_participants (interaction_id, person_id, role) values (iMeet, pA, 'organizer'), (iMeet, pB2, 'participant'), (iMeet, pC, 'participant');
  insert into public.crm_interaction_participants (interaction_id, organization_id) values (iMeet, o1);
  select count(*) into n from public.crm_interaction_participants where interaction_id = iMeet;
  r := r || jsonb_build_object('TC-SB460-V2.four', case when n = 4 then 'pass' else format('FAIL: %s', n) end);
  begin
    insert into public.crm_interaction_participants (interaction_id, person_id) values (iMeet, pA);
    r := r || jsonb_build_object('TC-SB460-V2.dup', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V2.dup', case when sqlstate = '23505' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_interaction_participants (interaction_id, person_id, organization_id) values (iMeet, pS, o1);
    r := r || jsonb_build_object('TC-SB460-V2.both', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V2.both', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_interaction_participants (interaction_id) values (iMeet);
    r := r || jsonb_build_object('TC-SB460-V2.neither', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V2.neither', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- V3: provenance
  begin
    insert into public.crm_interactions (interaction_type, source_type) values ('email', 'import');
    r := r || jsonb_build_object('TC-SB460-V3.no_confidence', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V3.no_confidence', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  insert into public.crm_interactions (interaction_type, source_type, source_ref, confidence)
    values ('email', 'import', 'mailbox_export_2026', 0.60) returning id into iImp;
  select source_type = 'import' and source_ref = 'mailbox_export_2026' and confidence = 0.60 and not is_confirmed
    into b from public.crm_interactions where id = iImp;
  r := r || jsonb_build_object('TC-SB460-V3.kept', case when b then 'pass' else 'FAIL' end);

  -- V4: sensitivity and the agent boundary
  insert into public.crm_interactions (interaction_type, title) values ('call', 'Weekly catch-up') returning id into iTmp;
  select sensitivity into st from public.crm_interactions where id = iTmp;
  r := r || jsonb_build_object('TC-SB460-V4.default_normal', case when st = 'normal' then 'pass' else 'FAIL: ' || st end);
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pS);
  insert into public.crm_interactions (interaction_type, title, sensitivity) values ('message', 'test-private-title', 'private') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pS);
  insert into public.crm_interactions (interaction_type, title, sensitivity) values ('meeting', 'test-sensitive-title', 'sensitive') returning id into iSens;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iSens, pS);
  insert into public.crm_interactions (interaction_type, title, sensitivity) values ('note', 'test-highly-sensitive-title', 'highly_sensitive') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pS);
  insert into public.crm_interactions (interaction_type, title) values ('email', 'Reclassify me') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pS);
  update public.crm_interactions set sensitivity = 'private' where id = iTmp;
  select count(*) into n from public.crm_audit_log where action = 'sensitivity_change' and entity_type = 'crm_interactions'
     and entity_id = iTmp and reason_code = 'normal_to_private';
  r := r || jsonb_build_object('TC-SB460-V4.change_audited', case when n = 1 then 'pass' else format('FAIL: %s', n) end);
  select count(*), count(*) filter (where sensitivity in ('sensitive','highly_sensitive')) into n, m
    from public.crm_interactions_for_agent(pS);
  r := r || jsonb_build_object('TC-SB460-V4.default_retrieval', case when n = 3 and m = 0 then 'pass' else format('FAIL: %s rows, %s restricted', n, m) end);
  begin
    perform * from public.crm_interactions_for_agent(pS, true);
    r := r || jsonb_build_object('TC-SB460-V4.no_reason', 'FAIL: returned');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V4.no_reason', case when sqlstate = '22023' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_interactions_for_agent(pS, true, 'qa_engagement_review');
  select count(*) into m from public.crm_audit_log where action = 'restricted_read' and entity_type = 'crm_interactions'
     and entity_id = pS and entity_count = 2 and reason_code = 'qa_engagement_review';
  r := r || jsonb_build_object('TC-SB460-V4.restricted_audited', case when n = 5 and m = 1 then 'pass' else format('FAIL: %s rows, %s audit', n, m) end);
  -- the facts function now follows the same convention
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pS, 'note', 'test-fact-value', 'sensitive');
  perform * from public.crm_facts_for_agent(pS, true, 'qa_engagement_facts');
  select count(*) into n from public.crm_audit_log where action = 'restricted_read' and entity_type = 'crm_facts'
     and entity_id = pS and reason_code = 'qa_engagement_facts';
  r := r || jsonb_build_object('TC-SB460-V4.facts_convention', case when n = 1 then 'pass' else format('FAIL: %s', n) end);

  -- V6: archive keeps history
  update public.crm_interactions set archived = true where id = iMeet;
  select count(*) into n from public.crm_interaction_participants where interaction_id = iMeet;
  select archived_at is not null into b from public.crm_interactions where id = iMeet;
  select count(*) into m from public.crm_audit_log where action = 'archive' and entity_type = 'crm_interactions' and entity_id = iMeet;
  r := r || jsonb_build_object('TC-SB460-V6.archive', case when n = 4 and b and m = 1 then 'pass' else format('FAIL: %s parts, stamped=%s, audit=%s', n, b, m) end);
  update public.crm_interactions set archived = false where id = iMeet;

  -- =============================================================== SB-459
  -- V1: links
  insert into public.crm_actions (title, person_id) values ('Send the photos', pA);
  insert into public.crm_actions (title, organization_id) values ('Renew the contract', o1);
  insert into public.crm_actions (title, interaction_id) values ('Share the minutes', iMeet);
  r := r || jsonb_build_object('TC-SB459-V1.linked', 'pass');
  begin
    insert into public.crm_actions (title) values ('Floating task');
    r := r || jsonb_build_object('TC-SB459-V1.unlinked', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB459-V1.unlinked', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- V2: completed_at follows status
  insert into public.crm_actions (title, person_id) values ('Return the book', pA) returning id into aDone;
  update public.crm_actions set status = 'done' where id = aDone;
  select completed_at is not null into b from public.crm_actions where id = aDone;
  r := r || jsonb_build_object('TC-SB459-V2.done_stamps', case when b then 'pass' else 'FAIL' end);
  update public.crm_actions set status = 'open' where id = aDone;
  select completed_at is null into b from public.crm_actions where id = aDone;
  r := r || jsonb_build_object('TC-SB459-V2.reopen_clears', case when b then 'pass' else 'FAIL' end);
  begin
    insert into public.crm_actions (title, person_id, status, completed_at) values ('Bad state', pA, 'open', now());
    r := r || jsonb_build_object('TC-SB459-V2.inconsistent', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB459-V2.inconsistent', case when sqlstate = '23514' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- V3: open / overdue / completed
  insert into public.crm_actions (title, person_id, due_at) values ('Future task', pQ, now() + interval '5 days');
  insert into public.crm_actions (title, person_id, due_at) values ('Late task', pQ, now() - interval '3 days');
  insert into public.crm_actions (title, person_id, status) values ('Finished task', pQ, 'done');
  insert into public.crm_actions (title, person_id, status) values ('Abandoned task', pQ, 'cancelled');
  select count(*) filter (where status = 'open'),
         count(*) filter (where status = 'open' and due_at < now()),
         count(*) filter (where status = 'done' and completed_at is not null)
    into n, m, k from public.crm_actions where person_id = pQ;
  r := r || jsonb_build_object('TC-SB459-V3', case when n = 2 and m = 1 and k = 1 then 'pass' else format('FAIL: open %s overdue %s done %s', n, m, k) end);

  -- V4: an interaction creates its next action
  insert into public.crm_interactions (interaction_type, title, occurred_at) values ('call', 'Intro call', now() - interval '1 day') returning id into iCall;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iCall, pF);
  insert into public.crm_interaction_participants (interaction_id, organization_id) values (iCall, o1);
  fx := public.crm_create_follow_up(iCall, 'Send the follow-up notes', now() + interval '2 days');
  select person_id = pF and interaction_id = iCall and sensitivity = 'normal' and status = 'open'
    into b from public.crm_actions where id = fx;
  r := r || jsonb_build_object('TC-SB459-V4.from_call', case when b then 'pass' else 'FAIL' end);
  fx := public.crm_create_follow_up(iSens, 'test-followup-title');
  select sensitivity into st from public.crm_actions where id = fx;
  r := r || jsonb_build_object('TC-SB459-V4.inherits_sensitivity', case when st = 'sensitive' then 'pass' else 'FAIL: ' || st end);
  fx := public.crm_create_follow_up(iSens, 'Book the room', null, 'low', null, 'normal');
  select sensitivity into st from public.crm_actions where id = fx;
  r := r || jsonb_build_object('TC-SB459-V4.explicit_override', case when st = 'normal' then 'pass' else 'FAIL: ' || st end);

  -- =============================================================== SB-458
  -- V1: last contact = latest past, live interaction
  insert into public.crm_interactions (interaction_type, occurred_at) values ('call', now() - interval '20 days') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pL);
  insert into public.crm_interactions (interaction_type, occurred_at) values ('email', now() - interval '10 days') returning id into iEmail;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iEmail, pL);
  insert into public.crm_interactions (interaction_type, occurred_at) values ('meeting', now() + interval '5 days') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pL);
  insert into public.crm_interactions (interaction_type, occurred_at, archived) values ('message', now() - interval '2 days', true) returning id into iMsg;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iMsg, pL);
  select * into x from public.crm_contact_signals where person_id = pL;
  r := r || jsonb_build_object('TC-SB458-V1', case when x.last_contact_type = 'email' and x.days_since_contact = 10
                                                     and x.last_contact_at = (select occurred_at from public.crm_interactions where id = iEmail)
                                                then 'pass' else format('FAIL: %s %s', x.last_contact_type, x.days_since_contact) end);

  -- V2: cadence drives the stale flag
  insert into public.crm_people (display_name, contact_cadence_days, relationship_priority) values ('Olive Testperson', 30, 1) returning id into pO;
  insert into public.crm_interactions (interaction_type, occurred_at) values ('call', now() - interval '45 days') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pO);
  insert into public.crm_people (display_name, contact_cadence_days) values ('Noel Testperson', 30) returning id into pN;
  insert into public.crm_interactions (interaction_type, occurred_at) values ('meal', now() - interval '10 days') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pN);
  insert into public.crm_people (display_name, contact_cadence_days) values ('Vic Testperson', 30) returning id into pV;
  insert into public.crm_people (display_name) values ('Xan Testperson') returning id into pX;
  insert into public.crm_interactions (interaction_type, occurred_at) values ('call', now() - interval '400 days') returning id into iTmp;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iTmp, pX);
  select is_contact_overdue and days_overdue = 15 into b from public.crm_contact_signals where person_id = pO;
  r := r || jsonb_build_object('TC-SB458-V2.overdue_15', case when b then 'pass' else 'FAIL' end);
  select not is_contact_overdue into b from public.crm_contact_signals where person_id = pN;
  r := r || jsonb_build_object('TC-SB458-V2.recent_ok', case when b then 'pass' else 'FAIL' end);
  select is_contact_overdue into b from public.crm_contact_signals where person_id = pV;
  r := r || jsonb_build_object('TC-SB458-V2.never_contacted_due', case when b then 'pass' else 'FAIL' end);
  select not is_contact_overdue and next_contact_due_at is null into b from public.crm_contact_signals where person_id = pX;
  r := r || jsonb_build_object('TC-SB458-V2.no_cadence_never_flagged', case when b then 'pass' else 'FAIL' end);
  select string_agg(display_name, ',') into st from (select display_name from public.crm_review_stale_relationships where user_id = ua) q;
  r := r || jsonb_build_object('TC-SB458-V2.review_queue', case when st = 'Olive Testperson,Vic Testperson' then 'pass' else 'FAIL: ' || coalesce(st, 'none') end);

  -- V3: overdue actions review masks restricted titles
  insert into public.crm_actions (title, person_id, due_at) values ('Call back about the quote', pO, now() - interval '2 days');
  insert into public.crm_actions (title, person_id, due_at, sensitivity) values ('test-masked-action-title', pO, now() - interval '1 day', 'sensitive');
  insert into public.crm_actions (title, person_id, due_at) values ('Next quarter check-in', pO, now() + interval '30 days');
  select count(*), count(*) filter (where title = '(restricted)'), count(*) filter (where title like 'test-masked%')
    into n, m, k from public.crm_review_overdue_actions where person_id = pO;
  r := r || jsonb_build_object('TC-SB458-V3', case when n = 2 and m = 1 and k = 0 then 'pass' else format('FAIL: %s rows, %s masked, %s leaked', n, m, k) end);

  -- V4: upcoming dates
  insert into public.crm_people (display_name) values ('Dee Testperson') returning id into pD;
  d := current_date + 5;
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pD, 'birthday', extract(month from d), extract(day from d), 1990);
  d := current_date + 40;
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pD, 'anniversary', extract(month from d), extract(day from d), 2015);
  select count(*), max(days_until), max(years) into n, m, k from public.crm_upcoming_dates(30) where person_id = pD;
  r := r || jsonb_build_object('TC-SB458-V4.window_30', case when n = 1 and m = 5 and k = extract(year from current_date + 5)::int - 1990
                                                        then 'pass' else format('FAIL: %s rows, days %s, years %s', n, m, k) end);
  select count(*) into n from public.crm_upcoming_dates(60) where person_id = pD;
  r := r || jsonb_build_object('TC-SB458-V4.window_60', case when n = 2 then 'pass' else format('FAIL: %s', n) end);
  insert into public.crm_people (display_name) values ('Eli Testperson') returning id into pE;
  insert into public.crm_important_dates (person_id, kind, month, day, year) values (pE, 'birthday', 2, 29, 2012);
  select next_date, days_until into d, n from public.crm_upcoming_dates(30, date '2027-02-20') where person_id = pE;
  r := r || jsonb_build_object('TC-SB458-V4.leap_day', case when d = date '2027-02-28' and n = 8 then 'pass' else format('FAIL: %s / %s', d, n) end);

  -- V5: explainable, no score
  select explanation into st from public.crm_contact_signals where person_id = pO;
  r := r || jsonb_build_object('TC-SB458-V5.explanation',
          case when st like '%cadence 30d%' and st like '%(call, 45 days ago)%' and st like '%15 days past cadence%'
                and st like '%2 overdue action(s)%' then 'pass' else 'FAIL: ' || coalesce(st, 'null') end);

  -- =============================================================== as user B
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  insert into public.crm_people (display_name) values ('Bea Testperson') returning id into pBo;

  -- SB-460 V5
  select count(*) into n from public.crm_interactions where user_id = ua;
  select count(*) into m from public.crm_interaction_participants where user_id = ua;
  r := r || jsonb_build_object('TC-SB460-V5.select', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s / %s', n, m) end);
  update public.crm_interactions set title = 'x' where user_id = ua;
  get diagnostics n = row_count;
  update public.crm_interaction_participants set role = 'other' where user_id = ua;
  get diagnostics m = row_count;
  r := r || jsonb_build_object('TC-SB460-V5.update', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s / %s', n, m) end);
  begin
    insert into public.crm_interaction_participants (interaction_id, person_id) values (iCall, pBo);
    r := r || jsonb_build_object('TC-SB460-V5.cross_owner_participant', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V5.cross_owner_participant', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    insert into public.crm_interactions (user_id, interaction_type) values (ua, 'note');
    r := r || jsonb_build_object('TC-SB460-V5.insert_as_other', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB460-V5.insert_as_other', case when sqlstate = '42501' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_interactions_for_agent(pS, true, 'qa_engagement_probe');
  r := r || jsonb_build_object('TC-SB460-V5.agent_function', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- SB-459 V1 (cross-owner) and V5
  begin
    insert into public.crm_actions (title, person_id) values ('Intruder task', pA);
    r := r || jsonb_build_object('TC-SB459-V1.cross_owner', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB459-V1.cross_owner', case when sqlstate = '23503' then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  select count(*) into n from public.crm_actions where user_id = ua;
  update public.crm_actions set status = 'cancelled' where user_id = ua;
  get diagnostics m = row_count;
  r := r || jsonb_build_object('TC-SB459-V5.select_update', case when n = 0 and m = 0 then 'pass' else format('FAIL: %s / %s', n, m) end);
  begin
    insert into public.crm_actions (user_id, title, person_id) values (ua, 'Forged task', pA);
    r := r || jsonb_build_object('TC-SB459-V5.insert_as_other', 'FAIL: accepted');
  exception when others then
    r := r || jsonb_build_object('TC-SB459-V5.insert_as_other', case when sqlstate in ('42501', '23503') then 'pass' else 'FAIL: ' || sqlstate end);
  end;
  begin
    perform public.crm_create_follow_up(iCall, 'Hijack');
    r := r || jsonb_build_object('TC-SB459-V4.foreign_interaction', 'FAIL: created');
  exception when others then
    r := r || jsonb_build_object('TC-SB459-V4.foreign_interaction', case when sqlstate = 'P0002' then 'pass' else 'FAIL: ' || sqlstate end);
  end;

  -- SB-458 V6
  select count(*) into n from public.crm_contact_signals where user_id = ua;
  select count(*) into m from public.crm_review_stale_relationships where user_id = ua;
  select count(*) into k from public.crm_review_overdue_actions where user_id = ua;
  r := r || jsonb_build_object('TC-SB458-V6.views', case when n = 0 and m = 0 and k = 0 then 'pass' else format('FAIL: %s/%s/%s', n, m, k) end);
  select count(*) into n from public.crm_upcoming_dates(366) where person_id in (pD, pE);
  r := r || jsonb_build_object('TC-SB458-V6.upcoming', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- =============================================================== catalog, as postgres
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  foreach t in array array['crm_interactions','crm_interaction_participants','crm_actions','crm_people'] loop
    begin
      perform public.crm_assert_owned_table(('public.' || t)::regclass);
      r := r || jsonb_build_object('catalog.owned.' || t, 'pass');
    exception when others then
      r := r || jsonb_build_object('catalog.owned.' || t, 'FAIL: ' || sqlerrm);
    end;
  end loop;
  select count(*) into n from pg_class
   where relname in ('crm_contact_signals','crm_review_stale_relationships','crm_review_overdue_actions')
     and reloptions @> array['security_invoker=true'];
  r := r || jsonb_build_object('TC-SB458-V6.security_invoker', case when n = 3 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name like 'crm\_%' and column_name ~ 'score';
  r := r || jsonb_build_object('TC-SB458-V5.no_score', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
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
   where a.user_id in (ua, ub) and to_jsonb(a)::text ~* '(testperson|example\.com|test-[a-z-]*title|test-fact-value)';
  r := r || jsonb_build_object('catalog.audit_no_content', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-ENGAGEMENT PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-ENGAGEMENT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;
