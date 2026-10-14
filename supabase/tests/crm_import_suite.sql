-- CRM import suite: TC-SB477-V1..V12 and TC-SB475-V2 (ADR-CRM-005).
--
-- Runs as two signed-in users inside one transaction that always ends by raising,
-- so every row it creates is rolled back. Run as postgres.
-- Pass = the raised message starts with "CRM-IMPORT PASS".

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; b boolean; t text; j jsonb; fails int; res jsonb; res2 jsonb;
  pM uuid; pS1 uuid; pS2 uuid; pAda uuid; pNew uuid;
  cFam uuid; cBd uuid; iEv uuid;
  p1 jsonb; p2 jsonb; p2b jsonb; p3 jsonb; pe jsonb; big jsonb;
  snap_before text; snap_after text; upd_s timestamptz; a_people int; a_audit int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- ------------------------------------------------------------------ seed (manual data)
  insert into public.crm_people (display_name, given_name, family_name)
    values ('Marlow Quince', 'Marlow', 'Quince') returning id into pM;
  insert into public.crm_contact_points (person_id, kind, value) values (pM, 'email', 'marlow@example.org');
  insert into public.crm_contact_points (person_id, kind, value) values (pM, 'phone', '+15550001111');
  insert into public.crm_people (display_name) values ('Shared One') returning id into pS1;
  insert into public.crm_people (display_name) values ('Shared Two') returning id into pS2;
  insert into public.crm_contact_points (person_id, kind, value) values (pS1, 'email', 'shared@example.org');
  insert into public.crm_contact_points (person_id, kind, value) values (pS2, 'email', 'shared@example.org');
  select updated_at into upd_s from public.crm_people where id = pS1;

  -- --------------------------------------------------- TC-SB477-V1: first import
  p1 := '{"format":"crm.contacts.v1","source":"google_contacts","source_label":"test-account","records":[
    {"external_id":"g1","given_name":"Ada","family_name":"Lovelace","emails":[{"value":"ada@example.org","preferred":true}],
     "organization":{"name":"Analytical Engines","title":"Engineer"},"birthday":{"month":12,"day":10,"year":1815}},
    {"external_id":"g2","display_name":"Brook Vale","phones":[{"value":"+1 555 0200"}]},
    {"external_id":"g3","given_name":"Cyd","family_name":"Stone"}]}';
  res := public.crm_import_contacts(p1, 'initial_load');
  select count(*) into n from public.crm_people
   where source_type = 'import' and confidence = 0.90 and not is_confirmed and source_ref = 'google_contacts:test-account';
  select count(*) into m from public.crm_external_ids where source = 'google_contacts' and entity_kind = 'person';
  select id into pAda from public.crm_people where display_name = 'Ada Lovelace';
  select count(*) into k from public.crm_contact_points
   where person_id = pAda and kind = 'email' and is_preferred and source_type = 'import';
  r := r || jsonb_build_object('TC-SB477-V1', case
         when (res->>'created')::int = 3 and (res->>'rejected')::int = 0 and n = 3 and m = 3 and k = 1
          and exists (select 1 from public.crm_affiliations a join public.crm_organizations o on o.id = a.organization_id
                       where a.person_id = pAda and o.name = 'Analytical Engines' and a.role_title = 'Engineer' and a.source_type = 'import')
          and exists (select 1 from public.crm_important_dates where person_id = pAda and kind = 'birthday' and year = 1815)
         then 'pass' else format('FAIL: %s people %s ids %s pref %s', res, n, m, k) end);

  -- --------------------------------------------------- TC-SB477-V2: idempotent
  select string_agg(x, ',') into snap_before from (
    select 'p' || count(*) from public.crm_people union all
    select 'c' || count(*) from public.crm_contact_points union all
    select 'o' || count(*) from public.crm_organizations union all
    select 'a' || count(*) from public.crm_affiliations union all
    select 'd' || count(*) from public.crm_important_dates union all
    select 'f' || count(*) from public.crm_facts union all
    select 'e' || count(*) from public.crm_external_ids union all
    select 'k' || count(*) from public.crm_import_conflicts) s(x);
  res := public.crm_import_contacts(p1, 'initial_load');
  select string_agg(x, ',') into snap_after from (
    select 'p' || count(*) from public.crm_people union all
    select 'c' || count(*) from public.crm_contact_points union all
    select 'o' || count(*) from public.crm_organizations union all
    select 'a' || count(*) from public.crm_affiliations union all
    select 'd' || count(*) from public.crm_important_dates union all
    select 'f' || count(*) from public.crm_facts union all
    select 'e' || count(*) from public.crm_external_ids union all
    select 'k' || count(*) from public.crm_import_conflicts) s(x);
  r := r || jsonb_build_object('TC-SB477-V2', case
         when (res->>'created')::int = 0 and (res->>'updated')::int = 0 and (res->>'unchanged')::int = 3
          and (res->>'conflicts')::int = 0 and snap_before = snap_after
         then 'pass' else format('FAIL: %s before %s after %s', res, snap_before, snap_after) end);

  -- ------------------------------ TC-SB477-V5 + V3 + V4: link by email, conflict, fill, add
  p2 := '{"format":"crm.contacts.v1","source":"google_contacts","source_label":"test-account","records":[
    {"external_id":"g9","given_name":"Marlow","middle_name":"J","family_name":"Quincy",
     "emails":[{"value":"Marlow@Example.org"},{"value":"marlow.new@example.org"}]}]}';
  select count(*) into a_people from public.crm_people;
  res := public.crm_import_contacts(p2, 'weekly_sync');
  select count(*) into n from public.crm_people;
  r := r || jsonb_build_object('TC-SB477-V5', case
         when (res->>'linked')::int = 1 and (res->>'created')::int = 0 and n = a_people
          and exists (select 1 from public.crm_external_ids where external_id = 'g9' and person_id = pM)
         then 'pass' else format('FAIL: %s people %s->%s', res, a_people, n) end);
  select id into cFam from public.crm_import_conflicts where person_id = pM and field = 'family_name' and status = 'open';
  r := r || jsonb_build_object('TC-SB477-V3.not_overwritten', case
         when (select family_name from public.crm_people where id = pM) = 'Quince' and cFam is not null
          and (select existing_value || '>' || incoming_value from public.crm_import_conflicts where id = cFam) = 'Quince>Quincy'
         then 'pass' else format('FAIL: family %s conflict %s', (select family_name from public.crm_people where id = pM), cFam) end);
  r := r || jsonb_build_object('TC-SB477-V4', case
         when (select middle_name from public.crm_people where id = pM) = 'J'
          and exists (select 1 from public.crm_contact_points where person_id = pM and value_normalized = 'marlow.new@example.org' and source_type = 'import')
          and exists (select 1 from public.crm_contact_points where person_id = pM and kind = 'phone' and value = '+15550001111' and not archived)
          and (select count(*) from public.crm_contact_points where person_id = pM and kind = 'email') = 2
         then 'pass' else 'FAIL: fill/add/keep' end);
  -- the same differing value again (record changed in another field) raises no second conflict
  p2b := jsonb_set(p2, '{records,0,urls}', '[{"value":"https://marlow.example.org"}]');
  res := public.crm_import_contacts(p2b, 'weekly_sync');
  select count(*) into n from public.crm_import_conflicts where person_id = pM and field = 'family_name';
  r := r || jsonb_build_object('TC-SB477-V3.raised_once', case
         when n = 1 and (res->>'conflicts')::int = 0 and (res->>'updated')::int = 1
         then 'pass' else format('FAIL: %s conflicts %s', res, n) end);

  -- --------------------------------------------------- TC-SB477-V6: ambiguous match
  res := public.crm_import_contacts('{"format":"crm.contacts.v1","source":"csv","records":[
    {"external_id":"row-7","given_name":"Shay","emails":[{"value":"shared@example.org"}]}]}', 'csv_upload');
  select id into pNew from public.crm_people where display_name = 'Shay';
  r := r || jsonb_build_object('TC-SB477-V6', case
         when (res->>'created')::int = 1 and pNew is not null and pNew not in (pS1, pS2)
          and (select updated_at from public.crm_people where id = pS1) = upd_s
          and (select count(*) from public.crm_contact_points where person_id in (pS1, pS2)) = 2
         then 'pass' else format('FAIL: %s', res) end);

  -- --------------------------------------------------- TC-SB477-V7: invalid records
  res := public.crm_import_contacts('{"format":"crm.contacts.v1","source":"vcard","source_label":"phone.vcf","records":[
    {"external_id":"v1","given_name":"Goodrecord"},
    {"given_name":"Noid"},
    {"external_id":"v3","given_name":"Bademail","emails":[{"value":"ZXQBADVALUE"}]},
    {"external_id":"v4","given_name":"Badday","birthday":{"month":2,"day":30}}]}', 'vcard_upload');
  select count(*) into n from public.crm_people where display_name in ('Noid', 'Bademail', 'Badday');
  select count(*) into m from public.crm_contact_points where value ilike '%ZXQBADVALUE%';
  r := r || jsonb_build_object('TC-SB477-V7', case
         when (res->>'created')::int = 1 and (res->>'rejected')::int = 3 and n = 0 and m = 0
          and res->'rejected_records' = '[{"index":1,"error":"missing_external_id"},{"index":2,"error":"invalid_email"},{"index":3,"error":"invalid_birthday"}]'::jsonb
          and res::text not ilike '%ZXQBADVALUE%'
         then 'pass' else format('FAIL: %s n %s m %s', res, n, m) end);

  -- --------------------------------------------------- TC-SB477-V11: took_incoming; kept_existing
  b := public.crm_resolve_import_conflict(cFam, 'took_incoming') = 'took_incoming';
  res := public.crm_import_contacts(jsonb_set(p2b, '{records,0,handles}', '[{"value":"@marlow"}]'), 'weekly_sync');
  r := r || jsonb_build_object('TC-SB477-V11.took_incoming', case
         when b and (select family_name from public.crm_people where id = pM) = 'Quincy'
          and (select confirmed_at is not null from public.crm_people where id = pM)
          and (select status from public.crm_import_conflicts where id = cFam) = 'took_incoming'
          and (res->>'conflicts')::int = 0
          and (select count(*) from public.crm_import_conflicts where person_id = pM) = 1
         then 'pass' else format('FAIL: %s', res) end);
  -- a different birthday for Ada: conflict, kept_existing leaves the date alone, and it cannot be resolved twice
  res := public.crm_import_contacts(jsonb_set(p1, '{records,0,birthday}', '{"month":12,"day":11,"year":1815}'), 'weekly_sync');
  select id into cBd from public.crm_import_conflicts where person_id = pAda and field = 'birthday';
  b := public.crm_resolve_import_conflict(cBd, 'kept_existing') = 'kept_existing';
  n := 0;
  begin perform public.crm_resolve_import_conflict(cBd, 'took_incoming');
  exception when others then if sqlstate = '22023' then n := 1; end if; end;
  r := r || jsonb_build_object('TC-SB477-V11.kept_existing', case
         when b and n = 1 and (res->>'conflicts')::int = 1
          and (select incoming_value from public.crm_import_conflicts where id = cBd) = '12-11-1815'
          and (select day from public.crm_important_dates where person_id = pAda and kind = 'birthday') = 10
         then 'pass' else format('FAIL: %s twice %s', res, n) end);

  -- --------------------------------------------------- TC-SB477-V10: interactions
  select count(*) into a_people from public.crm_people;
  pe := '{"format":"crm.interactions.v1","source":"google_calendar","source_label":"primary","records":[
    {"external_id":"ev1@2026-10-01","interaction_type":"meeting","occurred_at":"2026-10-01T15:00:00Z","ended_at":"2026-10-01T16:00:00Z",
     "title":"Planning","participant_emails":["ADA@example.org","unknown@nowhere.example"]},
    {"external_id":"ev2@2026-10-02","occurred_at":"2026-10-02T15:00:00Z","title":"Strangers only","participant_emails":["nobody@nowhere.example"]}]}';
  res := public.crm_import_interactions(pe, 'calendar_sync');
  select x.interaction_id into iEv from public.crm_external_ids x where x.external_id = 'ev1@2026-10-01';
  res2 := public.crm_import_interactions(pe, 'calendar_sync');
  r := r || jsonb_build_object('TC-SB477-V10.link_existing_only', case
         when (res->>'created')::int = 1 and (res->>'skipped')::int = 1
          and (res2->>'unchanged')::int = 1 and (res2->>'skipped')::int = 1 and (res2->>'created')::int = 0
          and (select count(*) from public.crm_people) = a_people
          and (select count(*) from public.crm_interaction_participants where interaction_id = iEv) = 1
          and exists (select 1 from public.crm_interaction_participants where interaction_id = iEv and person_id = pAda)
          and exists (select 1 from public.crm_interactions where id = iEv and source_type = 'import' and confidence = 0.60 and not is_confirmed)
          and not exists (select 1 from public.crm_contact_points where value_normalized like '%nowhere.example')
         then 'pass' else format('FAIL: %s / %s', res, res2) end);
  res := public.crm_import_interactions(jsonb_set(jsonb_set(pe, '{records,0,occurred_at}', '"2026-10-01T17:00:00Z"'), '{records,0,ended_at}', '"2026-10-01T18:00:00Z"'), 'calendar_sync');
  r := r || jsonb_build_object('TC-SB477-V10.rescheduled', case
         when (res->>'updated')::int = 1
          and (select occurred_at from public.crm_interactions where id = iEv) = '2026-10-01T17:00:00Z'::timestamptz
         then 'pass' else format('FAIL: %s', res) end);

  -- --------------------------------------------------- TC-SB477-V9: audit
  select count(*) into n from public.crm_audit_log
   where user_id = ua and action = 'bulk_import' and entity_type = 'crm_import_batches'
     and created_at >= now() - interval '1 minute';
  select count(*) into m from public.crm_import_batches where user_id = ua;
  select count(*) into k from public.crm_audit_log a
   where a.user_id = ua and to_jsonb(a)::text ~* '(example\.org|lovelace|quinc|marlow|ZXQBADVALUE|planning)';
  r := r || jsonb_build_object('TC-SB477-V9', case
         when n = m and n >= 9 and k = 0
          and not exists (select 1 from public.crm_audit_log a join public.crm_import_batches bt on bt.id = a.entity_id
                           where a.action = 'bulk_import' and a.entity_count <> bt.records_received)
          and exists (select 1 from public.crm_audit_log where user_id = ua and action = 'bulk_import' and reason_code = 'weekly_sync')
         then 'pass' else format('FAIL: audit %s batches %s content %s', n, m, k) end);

  -- --------------------------------------------------- TC-SB477-V12: contract errors
  n := 0;
  begin perform public.crm_import_contacts('{"format":"crm.contacts.v2","source":"csv","records":[]}', 'x_load');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform public.crm_import_contacts('{"format":"crm.contacts.v1","source":"csv","records":[]}', 'weekly sync');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  select jsonb_build_object('format','crm.contacts.v1','source','csv','records',
           jsonb_agg(jsonb_build_object('external_id', 'x' || g, 'given_name', 'X'))) into big
    from generate_series(1, 1001) g;
  begin perform public.crm_import_contacts(big, 'big_load');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform public.crm_import_contacts('{"format":"crm.contacts.v1","source":"myspace","records":[]}', 'x_load');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  r := r || jsonb_build_object('TC-SB477-V12.contract', case when n = 4 then 'pass' else format('FAIL: %s of 4 raised 22023', n) end);

  -- --------------------------------------------------- TC-SB477-V8: owner isolation
  select count(*) into a_people from public.crm_people where user_id = ua;
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  res := public.crm_import_contacts(p1, 'initial_load');
  n := 0;
  begin perform public.crm_resolve_import_conflict(cBd, 'dismissed');
  exception when others then if sqlstate = 'P0002' then n := 1; end if; end;
  select count(*) into m from public.crm_import_conflicts;     -- RLS: B sees only B's
  select count(*) into k from public.crm_external_ids where person_id = pAda;
  r := r || jsonb_build_object('TC-SB477-V8', case
         when (res->>'created')::int = 3 and (res->>'linked')::int = 0 and n = 1 and m = 0 and k = 0
         then 'pass' else format('FAIL: %s resolve %s conflicts seen %s ids seen %s', res, n, m, k) end);
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  select count(*) into n from public.crm_people where user_id = ua;
  select count(*) into m from public.crm_external_ids x where x.source = 'google_contacts' and x.external_id = 'g1';
  r := r || jsonb_build_object('TC-SB477-V8.a_untouched', case
         when n = a_people and m = 1 and (select status from public.crm_import_conflicts where id = cBd) = 'kept_existing'
         then 'pass' else format('FAIL: A people %s->%s g1 maps %s', a_people, n, m) end);

  -- no session
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  n := 0;
  begin perform public.crm_import_contacts(p1, 'initial_load');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.crm_import_interactions(pe, 'calendar_sync');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.crm_resolve_import_conflict(cBd, 'dismissed');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  r := r || jsonb_build_object('TC-SB477-V12.no_session', case when n = 3 then 'pass' else format('FAIL: %s of 3 raised 42501', n) end);

  -- --------------------------------------------------- catalog: TC-SB477-V12 privileges, TC-SB475-V2
  foreach t in array array['crm_import_batches','crm_external_ids','crm_import_conflicts'] loop
    begin
      perform public.crm_assert_owned_table(('public.' || t)::regclass);
      r := r || jsonb_build_object('TC-SB477-V12.owned.' || t, 'pass');
    exception when others then
      r := r || jsonb_build_object('TC-SB477-V12.owned.' || t, 'FAIL: ' || sqlerrm);
    end;
  end loop;
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute');
  select count(*) into m from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and has_function_privilege('anon', p.oid, 'execute');
  r := r || jsonb_build_object('TC-SB477-V12.functions', case when n = 0 and m = 0 then 'pass' else format('FAIL: definer %s anon %s', n, m) end);
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosrc ~* 'net\.http_';
  select count(*) into m from cron.job where command ~* 'crm_';
  r := r || jsonb_build_object('TC-SB475-V2', case when n = 0 and m = 0 then 'pass' else format('FAIL: net refs %s cron %s', n, m) end);
  select count(*) into n from pg_constraint c
   where c.contype = 'f' and c.conrelid::regclass::text like 'crm\_%'
     and not exists (select 1 from pg_index x where x.indrelid = c.conrelid
                       and (x.indkey::int2[])[0:array_length(c.conkey, 1) - 1] @> c.conkey);
  r := r || jsonb_build_object('catalog.fk_indexed', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-IMPORT PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-IMPORT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;
