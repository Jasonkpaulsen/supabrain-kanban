-- CRM agent intelligence suite: TC-SB473-V1..V5, TC-SB472-V1..V6, TC-SB471-V1..V7 (ADR-CRM-004).
--
-- Runs as two signed-in users inside one transaction that always ends by raising,
-- so every row it creates is rolled back. Run as postgres.
-- Pass = the raised message starts with "CRM-AGENT PASS".
-- A sentinel string is planted in a sensitive fact, a highly_sensitive interaction
-- and a sensitive follow-up; no default agent surface may ever return it.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  sentinel constant text := 'ZXQSENTINEL';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; b boolean; t text; j jsonb; fails int;
  tPar uuid; tSib uuid; tFr uuid;
  pK uuid; pC uuid; pS uuid; pF uuid; pD uuid; pE uuid; pR uuid; pN uuid; pQ1 uuid; pQ2 uuid;
  pArch uuid; pM1 uuid; pM2 uuid; pB uuid;
  oA uuid; i uuid; a1 uuid; aR uuid; fAgent uuid; fSable uuid; dis uuid; relSib uuid;
  audit_before int; key_a1 text; key_n text;
  before_people int; before_audit int; before_upd timestamptz;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select id into tPar from public.crm_relationship_types where user_id is null and code = 'parent';
  select id into tSib from public.crm_relationship_types where user_id is null and code = 'sibling';
  select id into tFr  from public.crm_relationship_types where user_id is null and code = 'friend';

  -- ------------------------------------------------------------------ seed
  insert into public.crm_people (display_name, pronouns, contact_cadence_days, relationship_priority)
    values ('Kestrel Ambrose', 'she/her', 30, 1) returning id into pK;
  insert into public.crm_people (display_name) values ('Corin Ambrose') returning id into pC;
  insert into public.crm_people (display_name) values ('Sable Ambrose') returning id into pS;
  insert into public.crm_people (display_name) values ('Fenwick Oldfriend') returning id into pF;
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pK, 'email', 'kestrel@example.com', true);
  insert into public.crm_contact_points (person_id, kind, value) values (pK, 'phone', '+15550101010');
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pK, pC, tPar);
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id, source_type, confidence)
    values (pK, pS, tSib, 'agent', 0.60) returning id into relSib;
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id, valid_from, valid_until)
    values (pK, pF, tFr, '2020-01-01', '2021-01-01');
  insert into public.crm_organizations (name) values ('Ambrose Labs') returning id into oA;
  insert into public.crm_affiliations (person_id, organization_id, role_title) values (pK, oA, 'Director');
  for n in 0..7 loop
    insert into public.crm_interactions (interaction_type, occurred_at, title, summary)
      values ('call', now() - make_interval(days => 45 + n), 'Catch-up ' || n,
              case when n = 0 then repeat('long ', 200) else 'talked about week ' || n end)
      returning id into i;
    insert into public.crm_interaction_participants (interaction_id, person_id) values (i, pK);
  end loop;
  insert into public.crm_interactions (interaction_type, occurred_at, title, summary, sensitivity)
    values ('meeting', now() - interval '60 days', 'Private matter', sentinel || ' interaction', 'highly_sensitive') returning id into i;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i, pK);
  insert into public.crm_interactions (interaction_type, occurred_at, title)
    values ('meeting', now() + interval '5 days', 'Future planning') returning id into i;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i, pK);
  for n in 1..24 loop
    insert into public.crm_facts (person_id, fact_type, value) values (pK, 'note_' || lpad(n::text, 2, '0'), 'fact number ' || n);
  end loop;
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
    values (pK, 'employer_guess', 'probably Ambrose Labs', 'agent', 'qa_agent', 0.50) returning id into fAgent;
  insert into public.crm_facts (person_id, fact_type, value, sensitivity, source_type, source_ref, confidence)
    values (pK, 'health_note', sentinel || ' fact', 'sensitive', 'agent', 'qa_agent', 0.40);
  insert into public.crm_facts (person_id, fact_type, value, archived) values (pK, 'old_note', 'archived fact text', true);
  -- Sable has one agent-sourced fact, so the confirmed-first fact bound cannot hide it (TC-SB472-V4)
  insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
    values (pS, 'nickname_guess', 'Sabe', 'agent', 'qa_agent', 0.70) returning id into fSable;
  insert into public.crm_actions (title, person_id, due_at) values ('Send the photos', pK, now() - interval '4 days') returning id into a1;
  insert into public.crm_actions (title, person_id, due_at, sensitivity)
    values (sentinel || ' follow-up', pK, now() - interval '3 days', 'sensitive') returning id into aR;
  for n in 1..10 loop
    insert into public.crm_actions (title, person_id, due_at) values ('Later task ' || n, pK, now() + make_interval(days => n));
  end loop;
  insert into public.crm_important_dates (person_id, kind, month, day, year)
    values (pK, 'birthday', extract(month from current_date + 10)::smallint, extract(day from current_date + 10)::smallint, 1984);

  insert into public.crm_people (display_name) values ('Dov Pending') returning id into pD;
  insert into public.crm_important_dates (person_id, kind, month, day, year)
    values (pD, 'birthday', extract(month from current_date + 5)::smallint, extract(day from current_date + 5)::smallint, 1986);
  insert into public.crm_people (display_name) values ('Esme Later') returning id into pE;
  insert into public.crm_important_dates (person_id, kind, month, day)
    values (pE, 'birthday', extract(month from current_date + 30)::smallint, extract(day from current_date + 30)::smallint);
  insert into public.crm_people (display_name, contact_cadence_days) values ('Rhea Recent', 30) returning id into pR;
  insert into public.crm_contact_points (person_id, kind, value) values (pR, 'phone', '+15550202020');
  insert into public.crm_interactions (interaction_type, occurred_at) values ('call', now() - interval '2 days') returning id into i;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i, pR);
  insert into public.crm_people (display_name, contact_cadence_days) values ('Nell Quiet', 60) returning id into pN;
  insert into public.crm_people (display_name) values ('Quinn Harrow') returning id into pQ1;
  insert into public.crm_people (display_name) values ('Quincy Harrow') returning id into pQ2;
  insert into public.crm_contact_points (person_id, kind, value) values (pQ1, 'email', 'qh@example.com'), (pQ2, 'email', 'QH@example.com');
  insert into public.crm_people (display_name, archived) values ('Archie Gone', true) returning id into pArch;
  insert into public.crm_people (display_name) values ('Mara Keep') returning id into pM1;
  insert into public.crm_people (display_name) values ('Mara Kept') returning id into pM2;
  perform public.crm_merge_people(pM1, pM2, 'same_person_confirmed');

  -- -------------------------------------------------------------- SB-473
  j := (select to_jsonb(c) from public.crm_person_card_for_agent(pK, 'meeting_prep') c);
  r := r || jsonb_build_object('TC-SB473-V1', case
         when j->>'display_name' = 'Kestrel Ambrose' and j->>'pronouns' = 'she/her'
          and (j->>'contact_cadence_days')::int = 30 and (j->>'relationship_priority')::int = 1
          and j->'contact_kinds' = '["email","phone"]'::jsonb and j->'preferred_contact_kinds' = '["email"]'::jsonb
          and j::text not like '%kestrel@example.com%' and j::text not like '%5550101010%'
         then 'pass' else 'FAIL: ' || coalesce(j::text, 'null') end);

  select count(*) into audit_before from public.crm_audit_log where action = 'agent_read';
  n := 0;
  begin perform * from public.crm_person_card_for_agent(pK, null);
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform * from public.crm_person_card_for_agent(pK, 'Meeting prep!');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  select count(*) into m from public.crm_audit_log where action = 'agent_read';
  perform * from public.crm_person_card_for_agent(pK, 'weekly_review');
  select count(*) into k from public.crm_audit_log
   where action = 'agent_read' and actor_kind = 'agent' and entity_type = 'crm_people' and entity_id = pK
     and reason_code = 'weekly_review' and entity_count = 1 and user_id = ua;
  r := r || jsonb_build_object('TC-SB473-V2', case when n = 2 and m = audit_before and k = 1 then 'pass'
                                                   else format('FAIL: rejected %s, audit after bad %s/%s, good rows %s', n, m, audit_before, k) end);

  n := 0;
  begin perform * from public.crm_person_card_for_agent(pArch, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  begin perform * from public.crm_person_card_for_agent(pM2, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  begin perform * from public.crm_person_card_for_agent(gen_random_uuid(), 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  r := r || jsonb_build_object('TC-SB473-V3.archived_merged_unknown', case when n = 3 then 'pass' else format('FAIL: %s of 3', n) end);

  -- -------------------------------------------------------------- SB-472
  select count(*) into audit_before from public.crm_audit_log where action = 'agent_read';
  j := public.crm_briefing(pK, 'meeting_prep');
  select count(*) into m from public.crm_audit_log
   where action = 'agent_read' and entity_id = pK and reason_code = 'meeting_prep'
     and entity_count = 1 + jsonb_array_length(j->'relationships') + jsonb_array_length(j->'affiliations')
                          + jsonb_array_length(j->'recent_interactions') + jsonb_array_length(j->'open_follow_ups')
                          + jsonb_array_length(j->'upcoming_dates') + jsonb_array_length(j->'facts');

  b := j->'person'->>'display_name' = 'Kestrel Ambrose'
   and (j->'signals'->>'is_contact_overdue')::boolean
   and exists (select 1 from jsonb_array_elements(j->'relationships') e
                where e->>'other_name' = 'Corin Ambrose'
                  and e->>'other_is' = (select coalesce(inverse_label, label) from public.crm_relationship_types where id = tPar))
   and exists (select 1 from jsonb_array_elements(j->'relationships') e where e->>'other_name' = 'Sable Ambrose')
   and exists (select 1 from jsonb_array_elements(j->'affiliations') e
                where e->>'organization' = 'Ambrose Labs' and e->>'role_title' = 'Director' and (e->>'is_current')::boolean)
   and j->'recent_interactions'->0->>'title' = 'Catch-up 0'
   and j->'open_follow_ups'->0->>'title' = 'Send the photos'
   and exists (select 1 from jsonb_array_elements(j->'upcoming_dates') e
                where e->>'kind' = 'birthday' and (e->>'days_until')::int = 10)
   and jsonb_array_length(j->'facts') > 0;
  r := r || jsonb_build_object('TC-SB472-V1', case when b then 'pass' else 'FAIL: ' || left(j::text, 600) end);

  select max(char_length(v)) into n from (
    select e->>'summary' v from jsonb_array_elements(j->'recent_interactions') e
    union all select e->>'title' from jsonb_array_elements(j->'recent_interactions') e
    union all select e->>'value' from jsonb_array_elements(j->'facts') e
    union all select e->>'title' from jsonb_array_elements(j->'open_follow_ups') e
    union all select e->>'context' from jsonb_array_elements(j->'relationships') e) x;
  r := r || jsonb_build_object('TC-SB472-V2', case
         when jsonb_array_length(j->'recent_interactions') = 5 and jsonb_array_length(j->'facts') = 20
          and jsonb_array_length(j->'open_follow_ups') = 10 and n <= 280
          and (j->'omitted'->>'interactions')::int = 3 and (j->'omitted'->>'facts')::int = 5
          and (j->'omitted'->>'follow_ups')::int = 2
         then 'pass' else format('FAIL: ints %s facts %s acts %s maxlen %s omitted %s',
                                 jsonb_array_length(j->'recent_interactions'), jsonb_array_length(j->'facts'),
                                 jsonb_array_length(j->'open_follow_ups'), n, j->'omitted') end);

  r := r || jsonb_build_object('TC-SB472-V3', case
         when j::text not like '%' || sentinel || '%'
          and (j->'omitted'->>'restricted_facts')::int = 1 and (j->'omitted'->>'restricted_interactions')::int = 1
          and exists (select 1 from jsonb_array_elements(j->'open_follow_ups') e
                       where (e->>'restricted')::boolean and e->>'title' = '(restricted)')
         then 'pass' else format('FAIL: sentinel %s, omitted %s', j::text like '%' || sentinel || '%', j->'omitted') end);

  select count(*) into n from (
    select e from jsonb_array_elements(j->'relationships') e
    union all select e from jsonb_array_elements(j->'affiliations') e
    union all select e from jsonb_array_elements(j->'facts') e
    union all select e from jsonb_array_elements(j->'recent_interactions') e) x
   where not (e ? 'id' and e ? 'confirmed' and e ? 'source_type');
  b := exists (select 1 from jsonb_array_elements(j->'relationships') e
                where (e->>'id')::uuid = relSib and e->>'confirmed' = 'false' and e->>'source_type' = 'agent')
   and exists (select 1 from jsonb_array_elements(public.crm_briefing(pS, 'meeting_prep')->'facts') e
                where (e->>'id')::uuid = fSable and e->>'confirmed' = 'false' and e->>'source_type' = 'agent');
  r := r || jsonb_build_object('TC-SB472-V4', case when n = 0 and b then 'pass' else format('FAIL: items missing keys %s, agent flags %s', n, b) end);

  n := 0;
  begin perform public.crm_briefing(pK, null);
  exception when others then if sqlstate = '22023' then n := 1; end if; end;
  r := r || jsonb_build_object('TC-SB472-V5', case when n = 1 and m = 1 then 'pass' else format('FAIL: null reason rejected %s, audit rows %s', n, m) end);

  n := 0;
  begin perform public.crm_briefing(pM2, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := 1; end if; end;
  b := not exists (select 1 from jsonb_array_elements(j->'relationships') e where e->>'other_name' = 'Fenwick Oldfriend')
   and j::text not like '%archived fact text%'
   and not exists (select 1 from jsonb_array_elements(j->'recent_interactions') e where e->>'title' = 'Future planning');
  r := r || jsonb_build_object('TC-SB472-V6.live_only', case when b and n = 1 then 'pass' else format('FAIL: live filters %s, merged P0002 %s', b, n) end);

  -- -------------------------------------------------------------- SB-471
  select count(*), max(updated_at) into before_people, before_upd from public.crm_people;
  select count(*) into before_audit from public.crm_audit_log;

  select count(*) into n from public.crm_recommendations(200) x
   where x.kind = 'overdue_follow_up' and x.source_ids->>'action_id' = a1::text and x.source_ids->>'person_id' = pK::text
     and x.reason like '%"Send the photos" was due %' and x.reason like '%(4 days ago)';
  select count(*) into m from public.crm_recommendations(200) x
   where x.kind = 'overdue_follow_up' and x.source_ids->>'action_id' = aR::text and x.title = 'Follow up: (restricted)';
  r := r || jsonb_build_object('TC-SB471-V1', case when n = 1 and m = 1 then 'pass' else format('FAIL: overdue %s, restricted masked %s', n, m) end);

  select count(*) into n from public.crm_recommendations(200) x
   where x.kind = 'contact_gap' and x.person_id = pK
     and x.reason = (select s.explanation from public.crm_contact_signals s where s.person_id = pK);
  select count(*) into m from public.crm_recommendations(200) x where x.kind = 'contact_gap' and x.person_id = pR;
  r := r || jsonb_build_object('TC-SB471-V2', case when n = 1 and m = 0 then 'pass' else format('FAIL: gap %s, recent listed %s', n, m) end);

  select count(*) into n from public.crm_recommendations(200) x
   where x.kind = 'upcoming_date' and x.person_id = pD
     and x.reason = 'birthday in 5 days (turns ' || (extract(year from current_date + 5)::int - 1986) || ')';
  select count(*) into m from public.crm_recommendations(200) x where x.kind = 'upcoming_date' and x.person_id = pE;
  r := r || jsonb_build_object('TC-SB471-V3', case when n = 1 and m = 0 then 'pass' else format('FAIL: 5-day %s, 30-day %s', n, m) end);

  select count(*) into n from public.crm_recommendations(200) x
   where x.kind = 'possible_duplicate' and x.subject_key = least(pQ1, pQ2)::text || ':' || greatest(pQ1, pQ2)::text
     and x.reason like 'shares an email address with %';
  select count(*) into m from public.crm_recommendations(200) x
   where x.kind = 'unconfirmed_fact' and x.source_ids->>'fact_id' = fAgent::text and x.reason like 'agent-added fact "employer_guess" (confidence 0.50) is unconfirmed';
  select count(*) into k from public.crm_recommendations(200) x where x.kind = 'no_contact_method' and x.person_id = pN;
  select count(*) into fails from public.crm_recommendations(200) x
   where x.kind = 'unconfirmed_fact' and x.person_id = pK and x.reason like '%health_note%';
  t := (select string_agg(to_jsonb(x)::text, ' ') from public.crm_recommendations(500) x);
  r := r || jsonb_build_object('TC-SB471-V4', case
         when n = 1 and m = 1 and k = 1 and fails = 0 and t not ilike '%qh@example.com%'
         then 'pass' else format('FAIL: dup %s fact %s unreachable %s restricted fact %s', n, m, k, fails) end);

  select x.subject_key into key_a1 from public.crm_recommendations(200) x where x.source_ids->>'action_id' = a1::text;
  select x.subject_key into key_n from public.crm_recommendations(200) x where x.kind = 'no_contact_method' and x.person_id = pN;
  dis := public.crm_dismiss_recommendation('overdue_follow_up', key_a1);
  select count(*) into n from public.crm_recommendations(200) x where x.subject_key = key_a1;
  b := false;
  begin perform public.crm_dismiss_recommendation('overdue_follow_up', key_a1);
  exception when others then b := sqlstate = '23505'; end;
  update public.crm_recommendation_dismissals set archived = true where id = dis;
  select count(*) into m from public.crm_recommendations(200) x where x.subject_key = key_a1;
  perform public.crm_dismiss_recommendation('no_contact_method', key_n, 'later', current_date + 1);
  select count(*) into k from public.crm_recommendations(200) x where x.subject_key = key_n;
  perform public.crm_dismiss_recommendation('overdue_follow_up', key_a1);
  update public.crm_actions set due_at = now() - interval '2 days' where id = a1;
  select count(*) into fails from public.crm_recommendations(200) x
   where x.source_ids->>'action_id' = a1::text and x.subject_key <> key_a1;
  t := 'none';
  begin perform public.crm_dismiss_recommendation('send_email', key_a1);
  exception when others then t := sqlstate; end;
  r := r || jsonb_build_object('TC-SB471-V5', case
         when n = 0 and b and m = 1 and k = 0 and fails = 1 and t = '22023' then 'pass'
         else format('FAIL: hidden %s twice-refused %s undo %s snoozed %s rescheduled %s unknown %s', n = 0, b, m, k, fails, t) end);

  select count(*) into n from public.crm_people;
  select count(*) into m from public.crm_audit_log;
  perform * from public.crm_recommendations(500);
  r := r || jsonb_build_object('TC-SB471-V6.no_writes', case
         when (select count(*) from public.crm_people) = n and (select count(*) from public.crm_audit_log) = m
          and (select max(updated_at) from public.crm_people) = before_upd
         then 'pass' else 'FAIL' end);

  -- ------------------------------------------- TC-SB473-V5: sentinel nowhere
  t := coalesce((select string_agg(to_jsonb(c)::text, ' ') from public.crm_person_card_for_agent(pK, 'qa_sweep') c), '')
    || coalesce(public.crm_briefing(pK, 'qa_sweep')::text, '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_recommendations(500) x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_search(sentinel) x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_facts_for_agent(pK) x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_interactions_for_agent(pK) x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_review_overdue_actions x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_review_stale_relationships x), '')
    || coalesce((select string_agg(to_jsonb(x)::text, ' ') from public.crm_upcoming_dates(60) x), '');
  r := r || jsonb_build_object('TC-SB473-V5', case when t not like '%' || sentinel || '%' and length(t) > 1000
                                                   then 'pass' else format('FAIL: sentinel present %s (len %s)', t like '%' || sentinel || '%', length(t)) end);

  -- --------------------------------------------------------- the other user
  -- Lift A's snooze on Nell first, so a leak of B's dismissal into A's list would show.
  update public.crm_recommendation_dismissals set archived = true
   where kind = 'no_contact_method' and subject_key = key_n and not archived;
  select count(*) into audit_before from public.crm_audit_log where user_id = ua;
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  insert into public.crm_people (display_name, contact_cadence_days) values ('Bea Otheruser', 30) returning id into pB;
  n := 0;
  begin perform * from public.crm_person_card_for_agent(pK, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  begin perform public.crm_briefing(pK, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := n + 1; end if; end;
  select count(*) into m from public.crm_recommendations(500) x
   where x.person_id in (pK, pD, pN, pQ1, pQ2) or x.source_ids::text like '%' || a1::text || '%';
  perform public.crm_dismiss_recommendation('no_contact_method', pN::text);   -- lands in B's own table
  r := r || jsonb_build_object('TC-SB473-V3.other_user', case when n = 2 then 'pass' else format('FAIL: %s of 2', n) end);
  r := r || jsonb_build_object('TC-SB472-V6.other_user', case when n = 2 then 'pass' else 'FAIL' end);

  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  select count(*) into k from public.crm_recommendations(500) x where x.kind = 'no_contact_method' and x.person_id = pN;
  select count(*) into fails from public.crm_audit_log where user_id = ua;
  r := r || jsonb_build_object('TC-SB471-V7', case when m = 0 and fails = audit_before then 'pass'
                                                   else format('FAIL: B saw %s, A audit changed %s->%s', m, audit_before, fails) end);
  -- B's dismissal must not reach A's list: A still sees Nell, and cannot see B's row
  select count(*) into n from public.crm_recommendation_dismissals where user_id = ub;
  r := r || jsonb_build_object('TC-SB471-V7.dismissal_isolated', case when n = 0 and k = 1 then 'pass'
                                                   else format('FAIL: A sees B dismissals %s, A list %s', n, k) end);

  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  n := 0;
  begin perform * from public.crm_person_card_for_agent(pK, 'meeting_prep');
  exception when others then if sqlstate = 'P0002' then n := 1; end if; end;
  select count(*) into m from public.crm_recommendations(50);
  r := r || jsonb_build_object('TC-SB471-V7.no_session', case when n = 1 and m = 0 then 'pass' else format('FAIL: card %s recs %s', n, m) end);

  -- ------------------------------------------------- TC-SB473-V4: catalog
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'v' and c.relname like 'crm\_%'
     and not coalesce(c.reloptions, '{}') @> array['security_invoker=true'];
  select count(*) into m from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute');
  select count(*) into k from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and has_function_privilege('anon', p.oid, 'execute');
  select count(*) into fails from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relname like 'crm\_%' and c.relkind in ('r','v')
     and exists (select 1 from aclexplode(c.relacl) a where a.grantee in (0, 'anon'::regrole::oid));
  b := (select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
         where s.nspname = 'public' and p.proname like 'crm\_%\_for\_agent')
       = array['crm_facts_for_agent','crm_interactions_for_agent','crm_person_card_for_agent']::name[]
   and exists (select 1 from pg_constraint where conname = 'crm_audit_log_action_check' and pg_get_constraintdef(oid) like '%agent_read%');
  r := r || jsonb_build_object('TC-SB473-V4', case when n = 0 and m = 0 and k = 0 and fails = 0 and b then 'pass'
                                                   else format('FAIL: views %s definer %s anon fn %s anon rel %s set %s', n, m, k, fails, b) end);

  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosrc ~* 'net\.http_';
  select count(*) into m from cron.job where command ~* 'crm_';
  r := r || jsonb_build_object('TC-SB471-V6.cannot_send', case
         when n = 0 and m = 0 and (select provolatile from pg_proc where oid = 'public.crm_recommendations(integer)'::regprocedure) = 's'
         then 'pass' else format('FAIL: net refs %s cron %s', n, m) end);

  begin
    perform public.crm_assert_owned_table('public.crm_recommendation_dismissals');
    r := r || jsonb_build_object('catalog.owned.crm_recommendation_dismissals', 'pass');
  exception when others then
    r := r || jsonb_build_object('catalog.owned.crm_recommendation_dismissals', 'FAIL: ' || sqlerrm);
  end;
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index x where x.indrelid = c.conrelid
                       and (x.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  r := r || jsonb_build_object('catalog.fk_indexed', case when n = 0 then 'pass' else format('FAIL: %s', n) end);
  select count(*) into n from public.crm_audit_log a
   where a.user_id in (ua, ub) and to_jsonb(a)::text ~* ('(example\.com|' || sentinel || '|kestrel|ambrose)');
  r := r || jsonb_build_object('catalog.audit_no_content', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-AGENT PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-AGENT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;
