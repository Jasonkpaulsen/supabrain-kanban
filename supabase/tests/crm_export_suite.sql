-- CRM export suite: TC-SB476-V1..V7 (ADR-CRM-005 §4).
--
-- Runs as two signed-in users inside one transaction that always ends by raising,
-- so every row it creates is rolled back. Run as postgres.
-- Pass = the raised message starts with "CRM-EXPORT PASS".
-- ZXQEXPORT marks restricted content; ZXQOTHEROWNER marks the other owner's data.
-- Neither may appear in a default export.

do $suite$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb;
  n int; m int; k int; b boolean; fails int;
  doc jsonb; doc_r jsonb; doc_a jsonb; pe jsonb;
  tFr uuid; pA uuid; pB uuid; pArch uuid; pM uuid; oX uuid; tT uuid; gG uuid; i1 uuid; iRestr uuid;
  aud_export int; aud_rr int;
begin
  -- ------------------------------------------------------------------ other owner first
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.crm_people (display_name) values ('ZXQOTHEROWNER Person');

  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  select id into tFr from public.crm_relationship_types where user_id is null and code = 'friend';

  -- ------------------------------------------------------------------ seed (owner A)
  insert into public.crm_people (display_name, given_name) values ('Exporta Ash', 'Exporta') returning id into pA;
  insert into public.crm_people (display_name) values ('Exportb Birch') returning id into pB;
  insert into public.crm_people (display_name) values ('Exportarch Gone') returning id into pArch;
  insert into public.crm_people (display_name) values ('Exportmerged Twin') returning id into pM;
  insert into public.crm_contact_points (person_id, kind, value, is_preferred) values (pA, 'email', 'exporta@example.net', true);
  insert into public.crm_contact_points (person_id, kind, value) values (pA, 'phone', '+15550009999');
  insert into public.crm_addresses (person_id, city) values (pA, 'Exportville');
  insert into public.crm_important_dates (person_id, kind, month, day) values (pA, 'birthday', 3, 14);
  insert into public.crm_facts (person_id, fact_type, value) values (pA, 'hobby', 'export normal fact');
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pA, 'note', 'export private fact', 'private');
  insert into public.crm_facts (person_id, fact_type, value, sensitivity) values (pA, 'health', 'ZXQEXPORT fact', 'sensitive');
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id) values (pA, pB, tFr);
  insert into public.crm_organizations (name) values ('Export Org') returning id into oX;
  insert into public.crm_affiliations (person_id, organization_id, role_title) values (pA, oX, 'Lead');
  insert into public.crm_tags (name) values ('export-tag') returning id into tT;
  insert into public.crm_entity_tags (tag_id, person_id) values (tT, pA);
  insert into public.crm_entity_tags (tag_id, organization_id) values (tT, oX);
  insert into public.crm_groups (name) values ('Export Group') returning id into gG;
  insert into public.crm_group_members (group_id, person_id) values (gG, pA);
  insert into public.crm_interactions (interaction_type, occurred_at, title) values ('call', now() - interval '2 days', 'Export call') returning id into i1;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (i1, pA);
  insert into public.crm_interactions (interaction_type, occurred_at, title, summary, sensitivity)
    values ('meeting', now() - interval '3 days', 'Export private meeting', 'ZXQEXPORT interaction', 'highly_sensitive') returning id into iRestr;
  insert into public.crm_interaction_participants (interaction_id, person_id) values (iRestr, pA);
  insert into public.crm_actions (title, person_id) values ('Export follow-up', pA);
  insert into public.crm_actions (title, person_id, sensitivity) values ('ZXQEXPORT action', pA, 'sensitive');
  update public.crm_people set archived = true where id = pArch;
  perform public.crm_merge_people(pB, pM, 'duplicate_entry');

  -- --------------------------------------------------- TC-SB476-V1: whole CRM, nested, counts true
  select count(*) into aud_export from public.crm_audit_log where user_id = ua and action = 'export';
  doc := public.crm_export('data_portability');
  select count(*) into n from public.crm_people where user_id = ua and not archived;
  select x into pe from jsonb_array_elements(doc->'people') x where x->>'id' = pA::text;
  r := r || jsonb_build_object('TC-SB476-V1.shape', case
         when doc->>'format' = 'crm.export.v1'
          and (doc->'counts'->>'people')::int = n and jsonb_array_length(doc->'people') = n
          and jsonb_array_length(pe->'contact_points') = 2
          and pe->'contact_points' @> '[{"kind":"email","value":"exporta@example.net","is_preferred":true}]'
          and jsonb_array_length(pe->'addresses') = 1 and jsonb_array_length(pe->'important_dates') = 1
          and jsonb_array_length(pe->'facts') = 2 and pe->'tags' @> '[{"name":"export-tag"}]'
          and pe->'groups' @> '[{"name":"Export Group"}]'
          and not (pe ? 'user_id') and not (pe ? 'name_normalized')
          and pe ? 'source_type' and pe ? 'captured_at'
         then 'pass' else format('FAIL: counts %s n %s person %s', doc->'counts', n, left(pe::text, 300)) end);
  r := r || jsonb_build_object('TC-SB476-V1.entities', case
         when doc->'organizations' @> jsonb_build_array(jsonb_build_object('id', oX, 'name', 'Export Org'))
          and exists (select 1 from jsonb_array_elements(doc->'organizations') o where o->>'id' = oX::text and o->'tags' @> '[{"name":"export-tag"}]')
          and doc->'affiliations' @> jsonb_build_array(jsonb_build_object('person_id', pA, 'organization_id', oX, 'role_title', 'Lead'))
          and doc->'relationships' @> jsonb_build_array(jsonb_build_object('person_id', pA, 'related_person_id', pB, 'type_code', 'friend'))
          and exists (select 1 from jsonb_array_elements(doc->'interactions') i
                       where i->>'id' = i1::text and jsonb_array_length(i->'participants') = 1)
          and doc->'actions' @> '[{"title":"Export follow-up"}]'
          and doc->'groups' @> '[{"name":"Export Group"}]' and doc->'tags' @> '[{"name":"export-tag"}]'
          and (doc->'counts'->>'organizations')::int = (select count(*) from public.crm_organizations where user_id = ua and not archived)
          and (doc->'counts'->>'interactions')::int = (select count(*) from public.crm_interactions
                                                       where user_id = ua and not archived and sensitivity in ('normal','private'))
         then 'pass' else format('FAIL: counts %s', doc->'counts') end);

  -- --------------------------------------------------- TC-SB476-V2: ownership
  r := r || jsonb_build_object('TC-SB476-V2', case
         when doc::text not ilike '%ZXQOTHEROWNER%' and doc::text not ilike ('%' || ub::text || '%')
          and doc::text not ilike ('%' || ua::text || '%')
         then 'pass' else 'FAIL: another owner''s data or a user id is in the export' end);

  -- --------------------------------------------------- TC-SB476-V3: restricted
  select count(*) into aud_rr from public.crm_audit_log where user_id = ua and action = 'restricted_read';
  doc_r := public.crm_export('data_portability', p_include_restricted => true);
  select count(*) into k from public.crm_audit_log where user_id = ua and action = 'restricted_read';
  r := r || jsonb_build_object('TC-SB476-V3', case
         when doc::text not ilike '%ZXQEXPORT%'
          and (doc->'omitted'->>'restricted_facts')::int >= 1 and (doc->'omitted'->>'restricted_interactions')::int >= 1
          and (doc->'omitted'->>'restricted_actions')::int >= 1
          and doc_r::text ilike '%ZXQEXPORT fact%' and doc_r::text ilike '%ZXQEXPORT interaction%' and doc_r::text ilike '%ZXQEXPORT action%'
          and (doc_r->'omitted'->>'restricted_facts')::int = 0
          and k = aud_rr + 1
         then 'pass' else format('FAIL: omitted %s restricted audit %s->%s', doc->'omitted', aud_rr, k) end);

  -- --------------------------------------------------- TC-SB476-V4: archived and merged
  doc_a := public.crm_export('data_portability', p_include_archived => true);
  r := r || jsonb_build_object('TC-SB476-V4', case
         when not (doc->'people' @> jsonb_build_array(jsonb_build_object('id', pArch)))
          and not (doc->'people' @> jsonb_build_array(jsonb_build_object('id', pM)))
          and (doc->'omitted'->>'archived_people')::int >= 2
          and doc_a->'people' @> jsonb_build_array(jsonb_build_object('id', pArch, 'archived', true))
          and doc_a->'people' @> jsonb_build_array(jsonb_build_object('id', pM, 'merged_into_id', pB))
         then 'pass' else format('FAIL: omitted %s', doc->'omitted') end);

  -- --------------------------------------------------- TC-SB476-V5: explicit, reason-coded, audited
  n := 0;
  begin perform public.crm_export(null);
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  begin perform public.crm_export('data portability please');
  exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
  select count(*) into m from public.crm_audit_log where user_id = ua and action = 'export';
  select count(*) into k from public.crm_audit_log a
   where a.user_id = ua and a.action = 'export' and a.entity_type = 'crm_people' and a.reason_code = 'data_portability'
     and a.entity_count = (doc->'counts'->>'people')::int and a.actor_kind = 'user';
  r := r || jsonb_build_object('TC-SB476-V5', case
         when n = 2 and m = aud_export + 3 and k >= 1
         then 'pass' else format('FAIL: raised %s, export audit %s->%s, matching %s', n, aud_export, m, k) end);
  select count(*) into n from public.crm_audit_log a
   where a.user_id = ua and to_jsonb(a)::text ~* '(ZXQEXPORT|exporta|example\.net|Exportville)';
  r := r || jsonb_build_object('TC-SB476-V5.audit_no_content', case when n = 0 then 'pass' else format('FAIL: %s', n) end);

  -- --------------------------------------------------- TC-SB476-V6: no session
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  n := 0;
  begin perform public.crm_export('data_portability');
  exception when others then if sqlstate = '42501' then n := 1; end if; end;
  r := r || jsonb_build_object('TC-SB476-V6', case when n = 1 then 'pass' else 'FAIL: no 42501 without a session' end);

  -- --------------------------------------------------- TC-SB476-V7: not an agent surface
  b := (select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
         where s.nspname = 'public' and p.proname like 'crm\_%\_for\_agent')
       = array['crm_facts_for_agent','crm_interactions_for_agent','crm_person_card_for_agent']::name[];
  r := r || jsonb_build_object('TC-SB476-V7', case
         when b and not (select prosecdef from pg_proc where oid = 'public.crm_export(text,boolean,boolean)'::regprocedure)
          and (select provolatile from pg_proc where oid = 'public.crm_export(text,boolean,boolean)'::regprocedure) = 'v'
          and not has_function_privilege('anon', 'public.crm_export(text,boolean,boolean)', 'execute')
         then 'pass' else 'FAIL: agent set, definer, volatility or anon grant' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'CRM-EXPORT PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CRM-EXPORT FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)),
      (select jsonb_object_agg(key, value) from jsonb_each_text(r) where value <> 'pass')::text;
  end if;
end $suite$;
