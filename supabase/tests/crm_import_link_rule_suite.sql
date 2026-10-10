-- CRM import link rule suite: TC-SB583-1..8 (SB-583; ADR-CRM-005 §3.4, ADR-CRM-006 §4 as amended).
--
-- An email is identity; a phone is only a clue. Runs as one signed-in owner inside one transaction
-- that always ends by raising, so every row it creates is rolled back. Run as postgres.
-- Pass = the raised message starts with "CRM-LINK-RULE PASS". Fixture names are invented;
-- zq.example addresses and +1 555 010 xxxx numbers mark fixture contacts. The raised message
-- carries only fixture values and counts, never the owner's own CRM data.
--
-- Each case is wrapped in its own sub-block, so an error in one case is reported as that case's
-- FAIL and does not stop the others.

do $suite$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  src constant text := '{"format":"crm.contacts.v1","source":"csv","source_label":"qa-sb583","records":[]}';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; fails int; st text; res jsonb;
  s0 jsonb; s1 jsonb; s2 jsonb; s3 jsonb;
  pE uuid; pP1 uuid; pP2 uuid; pO uuid; pR uuid; pT1 uuid; pT2 uuid; pM1 uuid; pM2 uuid;
  g1 uuid; g2 uuid; f1 uuid; f2 uuid; e1 uuid; e2 uuid; pNew uuid;
  fn text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ------------------------------------------------ TC-SB583-1: email links even when names differ
  begin
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Wystan Corrigal', 'Wystan', 'Corrigal') returning id into pE;
    insert into public.crm_contact_points (person_id, kind, value) values (pE, 'email', 'tc1@zq.example');
    select count(*) into n from public.crm_people;
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-1","given_name":"Pim","family_name":"Okonjo","emails":[{"value":"TC1@ZQ.example"}]}]'),
           'qa_sb583');
    select count(*) into m from public.crm_people;
    r := r || jsonb_build_object('TC-SB583-1', case
           when (res->>'linked')::int = 1 and (res->>'created')::int = 0 and m = n
            and exists (select 1 from public.crm_external_ids where external_id = 'sb583-1' and person_id = pE)
            and (select given_name || ' ' || family_name from public.crm_people where id = pE) = 'Wystan Corrigal'
           then 'pass' else format('FAIL: %s people %s->%s', res - 'batch_id', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-2: phone links when given names fit
  begin
    -- equal given name, phone written differently
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Ottilie Marchbank', 'Ottilie', 'Marchbank') returning id into pP1;
    insert into public.crm_contact_points (person_id, kind, value) values (pP1, 'phone', '+15550102001');
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-2a","given_name":"Ottilie","family_name":"Marchbank-Hale","phones":[{"value":"+1 555 010 2001"}]}]'),
           'qa_sb583');
    r := r || jsonb_build_object('TC-SB583-2.equal', case
           when (res->>'linked')::int = 1 and (res->>'created')::int = 0
            and exists (select 1 from public.crm_external_ids where external_id = 'sb583-2a' and person_id = pP1)
           then 'pass' else format('FAIL: %s', res - 'batch_id') end);
    -- alex / alexander prefix
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Alexander Vantongeren', 'Alexander', 'Vantongeren') returning id into pP2;
    insert into public.crm_contact_points (person_id, kind, value) values (pP2, 'phone', '+15550102002');
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-2b","given_name":"Alex","family_name":"Vantongeren","phones":[{"value":"+1 (555) 010-2002"}]}]'),
           'qa_sb583');
    r := r || jsonb_build_object('TC-SB583-2.prefix', case
           when (res->>'linked')::int = 1 and (res->>'created')::int = 0
            and exists (select 1 from public.crm_external_ids where external_id = 'sb583-2b' and person_id = pP2)
           then 'pass' else format('FAIL: %s', res - 'batch_id') end);
    -- helper unit checks (compatible: equal, prefix >= 3, preferred-name, display fallback; not: 2-letter prefix, titles)
    r := r || jsonb_build_object('TC-SB583-2.helpers', case
           when public.crm_given_names_compatible(public.crm_name_tokens('Alex', null, null), public.crm_name_tokens('Alexander', null, null))
            and public.crm_given_names_compatible(public.crm_name_tokens('Ottilie', null, null), public.crm_name_tokens(' OTTILIE ', null, null))
            and public.crm_given_names_compatible(public.crm_name_tokens('Barnaby', 'Barney', null), public.crm_name_tokens(null, null, 'Barney Quist'))
            and not public.crm_given_names_compatible(public.crm_name_tokens('Al', null, null), public.crm_name_tokens('Alexander', null, null))
            and not public.crm_given_names_compatible(public.crm_name_tokens('Henrike', null, null), public.crm_name_tokens('Bertil', null, null))
            and not public.crm_given_names_compatible(public.crm_name_tokens('Mrs', null, null), public.crm_name_tokens('Mrs', null, null))
            and public.crm_name_tokens(null, null, null) = '{}'::text[]
           then 'pass' else 'FAIL: helper truth table' end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-3: office line, different given name
  begin
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Henrike Dalmau', 'Henrike', 'Dalmau') returning id into pO;
    insert into public.crm_contact_points (person_id, kind, label, value) values (pO, 'phone', 'Work', '+15550103000');
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-3","given_name":"Bertil","family_name":"Sandquist",
               "emails":[{"value":"tc3.bertil@zq.example"}],"phones":[{"value":"+1 555 010 3000","label":"Work"}],
               "organization":{"name":"Zq Dalmau Office","title":"Clerk"}}]'),
           'qa_sb583');
    select x.person_id into pNew from public.crm_external_ids x where x.external_id = 'sb583-3' and x.source = 'csv';
    r := r || jsonb_build_object('TC-SB583-3', case
           when (res->>'created')::int = 1 and (res->>'linked')::int = 0
            and pNew is not null and pNew <> pO
            and (select display_name from public.crm_people where id = pNew) = 'Bertil Sandquist'
            and (select count(*) from public.crm_contact_points where person_id = pO) = 1
            and not exists (select 1 from public.crm_affiliations where person_id = pO)
            and not exists (select 1 from public.crm_import_conflicts where person_id = pO)
            and exists (select 1 from public.crm_contact_points where person_id = pNew and kind = 'phone' and value_normalized = '+15550103000')
            and exists (select 1 from public.crm_duplicate_candidates(1000) c
                         where c.person_a = least(pO, pNew) and c.person_b = greatest(pO, pNew)
                           and c.strength = 'strong' and 'same phone +15550103000' = any(c.reasons))
            and exists (select 1 from public.crm_recommendations(500) x
                         where x.kind = 'possible_duplicate' and x.subject_key = least(pO, pNew)::text || ':' || greatest(pO, pNew)::text)
           then 'pass' else format('FAIL: %s new %s', res - 'batch_id', pNew is not null) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-4: relatives (same surname) on a landline
  begin
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Linnea Thorsby', 'Linnea', 'Thorsby') returning id into pR;
    insert into public.crm_contact_points (person_id, kind, label, value) values (pR, 'phone', 'Home', '+15550104000');
    insert into public.crm_important_dates (person_id, kind, month, day) values (pR, 'birthday', 5, 9);
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-4","given_name":"Gunnar","family_name":"Thorsby",
               "phones":[{"value":"+1 555 010 4000","label":"Home"}],"birthday":{"month":11,"day":2}}]'),
           'qa_sb583');
    pNew := null;
    select x.person_id into pNew from public.crm_external_ids x where x.external_id = 'sb583-4' and x.source = 'csv';
    r := r || jsonb_build_object('TC-SB583-4', case
           when (res->>'created')::int = 1 and (res->>'linked')::int = 0 and (res->>'conflicts')::int = 0
            and pNew is not null and pNew <> pR
            and (select given_name from public.crm_people where id = pNew) = 'Gunnar'
            and (select given_name from public.crm_people where id = pR) = 'Linnea'
            and (select count(*) from public.crm_important_dates where person_id = pR) = 1
            and (select month from public.crm_important_dates where person_id = pR) = 5
            and exists (select 1 from public.crm_duplicate_candidates(1000) c
                         where c.person_a = least(pR, pNew) and c.person_b = greatest(pR, pNew)
                           and 'same phone +15550104000' = any(c.reasons))
           then 'pass' else format('FAIL: %s new %s', res - 'batch_id', pNew is not null) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-5: phone on two compatible people
  begin
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Marit Solvang', 'Marit', 'Solvang') returning id into pT1;
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Marit Solvang-Ree', 'Marit', 'Solvang-Ree') returning id into pT2;
    insert into public.crm_contact_points (person_id, kind, value) values (pT1, 'phone', '+15550105000'), (pT2, 'phone', '+1 555 010 5000');
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-5","given_name":"Marit","family_name":"Solvang","phones":[{"value":"+15550105000"}]}]'),
           'qa_sb583');
    pNew := null;
    select x.person_id into pNew from public.crm_external_ids x where x.external_id = 'sb583-5' and x.source = 'csv';
    r := r || jsonb_build_object('TC-SB583-5', case
           when (res->>'created')::int = 1 and (res->>'linked')::int = 0
            and pNew is not null and pNew not in (pT1, pT2)
            and (select count(*) from public.crm_contact_points where person_id in (pT1, pT2)) = 2
           then 'pass' else format('FAIL: %s', res - 'batch_id') end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-6: email on two people (no phone fallback)
  begin
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Quillon Arvest', 'Quillon', 'Arvest') returning id into pM1;
    insert into public.crm_people (display_name, given_name, family_name)
      values ('Saffi Arvest', 'Saffi', 'Arvest') returning id into pM2;
    insert into public.crm_contact_points (person_id, kind, value)
      values (pM1, 'email', 'tc6@zq.example'), (pM2, 'email', 'tc6@zq.example'), (pM1, 'phone', '+15550106000');
    -- the phone alone would link to Quillon (unique, same given name); the ambiguous email must win
    res := public.crm_import_contacts(jsonb_set(src::jsonb, '{records}',
             '[{"external_id":"sb583-6","given_name":"Quillon","family_name":"Arvest",
               "emails":[{"value":"tc6@zq.example"}],"phones":[{"value":"+1 555 010 6000"}]}]'),
           'qa_sb583');
    pNew := null;
    select x.person_id into pNew from public.crm_external_ids x where x.external_id = 'sb583-6' and x.source = 'csv';
    r := r || jsonb_build_object('TC-SB583-6', case
           when (res->>'created')::int = 1 and (res->>'linked')::int = 0
            and pNew is not null and pNew not in (pM1, pM2)
            and (select count(*) from public.crm_contact_points where person_id = pM1) = 2
            and (select count(*) from public.crm_contact_points where person_id = pM2) = 1
           then 'pass' else format('FAIL: %s', res - 'batch_id') end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-7: steward auto_merge_contact phone guard
  -- A dry run undoes its own work, so the effect of each fixture pair is the change in
  -- merges.merged between dry runs taken before and after that pair is added.
  begin
    s0 := public.crm_steward_run(true, 200);
    -- (g) shared phone, same given name, same surname: merges
    insert into public.crm_people (display_name, given_name, family_name) values ('Rhosyn Eckhart', 'Rhosyn', 'Eckhart') returning id into g1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Rhosyn Eckhart', 'Rhosyn', 'Eckhart') returning id into g2;
    insert into public.crm_contact_points (person_id, kind, value) values (g1, 'phone', '+15550107001'), (g2, 'phone', '+1 555 010 7001');
    s1 := public.crm_steward_run(true, 200);
    -- (f) shared phone, same surname, different given name (relatives): must not merge
    insert into public.crm_people (display_name, given_name, family_name) values ('Ingram Feldhaus', 'Ingram', 'Feldhaus') returning id into f1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Petronella Feldhaus', 'Petronella', 'Feldhaus') returning id into f2;
    insert into public.crm_contact_points (person_id, kind, value) values (f1, 'phone', '+15550107002'), (f2, 'phone', '+15550107002');
    s2 := public.crm_steward_run(true, 200);
    -- (e) control: shared email, same surname, different given name still merges (rule unchanged)
    insert into public.crm_people (display_name, given_name, family_name) values ('Corisande Haldane', 'Corisande', 'Haldane') returning id into e1;
    insert into public.crm_people (display_name, given_name, family_name) values ('Ewart Haldane', 'Ewart', 'Haldane') returning id into e2;
    insert into public.crm_contact_points (person_id, kind, value) values (e1, 'email', 'tc7e@zq.example'), (e2, 'email', 'tc7e@zq.example');
    s3 := public.crm_steward_run(true, 200);
    select count(*) into n from public.crm_duplicate_candidates(1000) c
     where (c.person_a, c.person_b) in ((least(g1, g2), greatest(g1, g2)), (least(f1, f2), greatest(f1, f2)))
       and exists (select 1 from unnest(c.reasons) x where x like 'same phone %');
    select count(*) into m from public.crm_people where id in (g1, g2, f1, f2, e1, e2) and not archived and merged_into_id is null;
    r := r || jsonb_build_object('TC-SB583-7', case
           when (s1->'merges'->>'merged')::int = (s0->'merges'->>'merged')::int + 1
            and (s2->'merges'->>'merged')::int = (s1->'merges'->>'merged')::int
            and (s3->'merges'->>'merged')::int = (s2->'merges'->>'merged')::int + 1
            and (s3->'merges'->>'errors')::int = 0 and not (s3->'merges'->>'suspended')::boolean
            and (s3->>'dry_run')::boolean and n = 2 and m = 6
           then 'pass' else format('FAIL: merged %s/%s/%s/%s errors %s phone-cands %s live %s',
                                   s0->'merges'->'merged', s1->'merges'->'merged', s2->'merges'->'merged',
                                   s3->'merges'->'merged', s3->'merges'->'errors', n, m) end);
    r := r || jsonb_build_object('TC-SB583-7.evidence', format('merged base=%s +same_given_phone=%s +relatives_phone=%s +email_control=%s',
                                   s0->'merges'->'merged', s1->'merges'->'merged', s2->'merges'->'merged', s3->'merges'->'merged'));
  exception when others then
    r := r || jsonb_build_object('TC-SB583-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB583-8: security posture of the four functions
  begin
    select count(*) into n from pg_proc
     where oid in ('public.crm_import_contacts(jsonb,text)'::regprocedure,
                   'public.crm_steward_run(boolean,integer)'::regprocedure,
                   'public.crm_name_tokens(text,text,text)'::regprocedure,
                   'public.crm_given_names_compatible(text[],text[])'::regprocedure)
       and not prosecdef and proconfig @> array['search_path=""']
       and not has_function_privilege('anon', oid, 'execute')
       and has_function_privilege('authenticated', oid, 'execute');
    select count(*) into m from pg_proc
     where oid in ('public.crm_name_tokens(text,text,text)'::regprocedure,
                   'public.crm_given_names_compatible(text[],text[])'::regprocedure)
       and provolatile = 'i';
    -- anon is refused at the privilege check (42501) for the two helpers
    k := 0;
    foreach fn in array array['select public.crm_name_tokens(''a'', null, null)',
                              'select public.crm_given_names_compatible(''{a}'', ''{a}'')'] loop
      st := null;
      begin
        set local role anon;
        execute fn;
        st := 'no error';
        set local role authenticated;
      exception when others then
        st := sqlstate;
      end;
      if st = '42501' then k := k + 1; end if;
    end loop;
    r := r || jsonb_build_object('TC-SB583-8', case
           when n = 4 and m = 2 and k = 2 and current_user = 'authenticated'
           then 'pass' else format('FAIL: posture ok %s of 4, immutable %s of 2, anon refused %s of 2, role %s', n, m, k, current_user) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB583-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-LINK-RULE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'CRM-LINK-RULE FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
