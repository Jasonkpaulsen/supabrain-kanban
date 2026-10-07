-- SB-577 (ADR-CRM-006 §2, §3, §6, §7): load the CRM from data already in OpenBrain.
--
-- * crm_steward_decisions: append-only, content-free log of every automatic decision.
-- * crm_source_tier(source_type, source_ref): provenance -> trust tier A / B / C.
-- * crm_policy_confirm_person(person, 'tier_a'): confirms a Tier A person and its rows from
--   the same source, records meta.confirmed_by = 'policy:tier_a', logs one decision per row.
-- * Builders, one per source table, return a crm.contacts.v1 payload of the CALLER's rows only
--   (source manual_json, reserved labels household / openbrain.<table>). No PII is in this
--   file: names are read at run time, and the owner's own name is an argument.
-- * crm_load_household(owner, reason) and crm_load_internal_sources(reason) send the payloads
--   through crm_import_contacts, then add what the contract does not carry (groups, members,
--   relationships), find-or-create, so a re-run changes nothing.

-- ---------------------------------------------------------------- decision log
-- Like crm_merge_log: no foreign keys, so it outlives what it names; append-only for every role.
create table public.crm_steward_decisions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid(),
  actor_id     uuid default auth.uid(),
  decision     text not null check (decision in ('auto_confirm','auto_merge','auto_resolve','auto_expire',
                                                 'auto_dismiss','suspend','resume','qa_verdict')),
  rule         text not null check (rule ~ '^[a-z0-9_]{3,64}$'),
  entity_type  text not null check (entity_type ~ '^crm_[a-z_]{1,60}$'),
  entity_id    uuid,
  reason_code  text not null check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  merge_log_id uuid,
  run_id       uuid,
  refers_to    uuid,
  qa_verdict   text check (qa_verdict in ('correct','wrong')),
  created_at   timestamptz not null default now(),
  check ((decision = 'qa_verdict') = (qa_verdict is not null and refers_to is not null))
);
comment on table public.crm_steward_decisions is
  'SB-577 / ADR-CRM-006 §7. One row per automatic steward decision: what, by which rule, on which row, '
  'with the undo handle for merges. Holds no names or values. Append-only.';

create index crm_steward_decisions_user_time on public.crm_steward_decisions (user_id, created_at desc);
create index crm_steward_decisions_entity on public.crm_steward_decisions (entity_id) where entity_id is not null;

create trigger trg_crm_steward_decisions_append_only
  before update or delete on public.crm_steward_decisions
  for each row execute function public.crm_append_only();

alter table public.crm_steward_decisions enable row level security;
revoke all on public.crm_steward_decisions from public, anon, authenticated;
grant select, insert on public.crm_steward_decisions to authenticated;
create policy crm_steward_decisions_select_own on public.crm_steward_decisions
  for select to authenticated using (user_id = (select auth.uid()));
create policy crm_steward_decisions_insert_own on public.crm_steward_decisions
  for insert to authenticated with check (user_id = (select auth.uid()) and actor_id = (select auth.uid()));

-- ---------------------------------------------------------------- tiers
create function public.crm_source_tier(p_source_type text, p_source_ref text)
returns text
language sql immutable parallel safe
set search_path = '' as $fn$
  select case
    when p_source_type = 'manual' then 'A'
    when p_source_type = 'agent' then 'C'
    when p_source_ref = 'manual_json:household' then 'A'
    when p_source_ref like 'manual_json:openbrain.%' then 'B'
    when split_part(coalesce(p_source_ref, ''), ':', 1)
         in ('apple_contacts','vcard','google_contacts','outlook','csv') then 'A'
    else 'C'
  end
$fn$;
comment on function public.crm_source_tier(text, text) is
  'ADR-CRM-006 §2. Trust tier of a CRM row from its provenance: A Jason-authored, B structured system data, C inferred.';
revoke all on function public.crm_source_tier(text, text) from public, anon;
grant execute on function public.crm_source_tier(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------- policy confirmation
create function public.crm_policy_confirm_person(p_person_id uuid, p_policy text)
returns integer
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  v_person public.crm_people%rowtype;
  v_ref    text;
  v_tag    jsonb;
  v_reason text;
  v_n      int := 0;
  t        text;
  v_rid    uuid;
begin
  if v_uid is null then
    raise exception 'policy confirmation needs a signed-in owner' using errcode = '42501';
  end if;
  if p_policy is distinct from 'tier_a' then
    raise exception 'unknown confirmation policy %', coalesce(p_policy, '(null)') using errcode = '22023';
  end if;
  select * into v_person from public.crm_people p
   where p.id = p_person_id and p.user_id = v_uid and not p.archived;
  if v_person.id is null then
    raise exception 'no such live person for this owner' using errcode = '42501';
  end if;
  if public.crm_source_tier(v_person.source_type, v_person.source_ref) <> 'A' then
    raise exception 'policy tier_a applies only to Tier A people' using errcode = '22023';
  end if;
  if v_person.source_type = 'manual' then
    return 0;  -- manual rows are confirmed by definition
  end if;

  v_ref := v_person.source_ref;
  v_tag := jsonb_build_object('confirmed_by', 'policy:' || p_policy);
  v_reason := 'auto_confirm_' || p_policy;

  -- The person and every unconfirmed live row it carries from the same Tier A source.
  -- Never a row the owner edited after capture, never a restricted fact (ADR-CRM-006 §3).
  for t, v_rid in
    select 'crm_people', x.id from public.crm_people x
     where x.id = v_person.id and x.user_id = v_uid and x.confirmed_at is null
    union all
    select 'crm_contact_points', x.id from public.crm_contact_points x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_affiliations', x.id from public.crm_affiliations x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_important_dates', x.id from public.crm_important_dates x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_person_relationships', x.id from public.crm_person_relationships x
     where (x.person_id = v_person.id or x.related_person_id = v_person.id) and x.user_id = v_uid
       and x.source_ref = v_ref and x.confirmed_at is null and not x.archived
       and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_facts', x.id from public.crm_facts x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref
       and x.sensitivity in ('normal','private')
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
  loop
    execute format('update public.%I set confirmed_at = now(), meta = meta || $1 where id = $2 and user_id = $3', t)
      using v_tag, v_rid, v_uid;
    insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code)
    values ('auto_confirm', p_policy, t, v_rid, v_reason);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $fn$;
comment on function public.crm_policy_confirm_person(uuid, text) is
  'ADR-CRM-006 §3. Confirm a Tier A person and its same-source rows by policy; one decision row per row confirmed.';
revoke all on function public.crm_policy_confirm_person(uuid, text) from public, anon;
grant execute on function public.crm_policy_confirm_person(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------- shared helpers
-- The owner's household children: family projects the owner's school or care rows point at.
create function public.crm_household_children()
returns table (project_id uuid, project_name text)
language sql stable security invoker
set search_path = '' as $fn$
  select p.id, p.name
    from public.projects p
   where p.user_id = (select auth.uid()) and p.domain = 'family'
     and (exists (select 1 from public.school_courses s
                   where s.user_id = (select auth.uid()) and s.child_project_id = p.id)
       or exists (select 1 from public.health_providers h
                   where h.user_id = (select auth.uid()) and h.child_project_id = p.id))
$fn$;

-- One row per distinct teacher of the owner's courses: by email, else by normalized name.
create function public.crm_school_teachers()
returns table (external_id text, display_name text, email text, school text, title text, child_project_ids uuid[])
language sql stable security invoker
set search_path = '' as $fn$
  with raw as (
    select btrim(s.teacher_of_record) as name, nullif(lower(btrim(s.teacher_email)), '') as email,
           nullif(btrim(s.school), '') as school, true as is_lead, s.child_project_id, s.created_at
      from public.school_courses s
     where s.user_id = (select auth.uid()) and nullif(btrim(s.teacher_of_record), '') is not null
    union all
    select btrim(s.co_teacher), nullif(lower(btrim(s.co_teacher_email)), ''),
           nullif(btrim(s.school), ''), false, s.child_project_id, s.created_at
      from public.school_courses s
     where s.user_id = (select auth.uid()) and nullif(btrim(s.co_teacher), '') is not null
  ), keyed as (
    select r.*, coalesce(max(r.email) over (partition by lower(regexp_replace(r.name, '\s+', ' ', 'g'))),
                         lower(regexp_replace(r.name, '\s+', ' ', 'g'))) as k
      from raw r
  )
  select 'school_courses:teacher:' || md5(k),
         (array_agg(name order by created_at))[1],
         max(email),
         (array_agg(school order by created_at) filter (where school is not null))[1],
         case when bool_or(is_lead) then 'Teacher' else 'Co-teacher' end,
         array_agg(distinct child_project_id) filter (where child_project_id is not null)
    from keyed
   group by k
$fn$;

revoke all on function public.crm_household_children() from public, anon;
revoke all on function public.crm_school_teachers() from public, anon;
grant execute on function public.crm_household_children() to authenticated, service_role;
grant execute on function public.crm_school_teachers() to authenticated, service_role;

-- ---------------------------------------------------------------- builders (crm.contacts.v1)
create function public.crm_build_contacts_household(p_owner jsonb)
returns jsonb
language plpgsql stable security invoker
set search_path = '' as $fn$
declare
  v_records jsonb;
begin
  if p_owner is null or jsonb_typeof(p_owner) <> 'object'
     or coalesce(nullif(btrim(p_owner->>'display_name'), ''), nullif(btrim(p_owner->>'given_name'), '')) is null then
    raise exception 'the owner''s name is required (given_name or display_name)' using errcode = '22023';
  end if;
  select jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'external_id', 'household:owner',
           'display_name', nullif(btrim(p_owner->>'display_name'), ''),
           'given_name', nullif(btrim(p_owner->>'given_name'), ''),
           'middle_name', nullif(btrim(p_owner->>'middle_name'), ''),
           'family_name', nullif(btrim(p_owner->>'family_name'), ''))))
         || coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'external_id', 'household:child:' || c.project_id,
              'display_name', btrim(c.project_name),
              'given_name', w[1],
              'middle_name', case when cardinality(w) > 2 then array_to_string(w[2:cardinality(w) - 1], ' ') end,
              'family_name', case when cardinality(w) > 1 then w[cardinality(w)] end))
            order by c.project_name), '[]'::jsonb)
    into v_records
    from (select hc.*, regexp_split_to_array(btrim(hc.project_name), '\s+') as w
            from public.crm_household_children() hc) c;
  return jsonb_build_object('format', 'crm.contacts.v1', 'source', 'manual_json', 'source_label', 'household',
                            'include_notes', false, 'records', v_records);
end $fn$;

create function public.crm_build_contacts_condo()
returns jsonb
language sql stable security invoker
set search_path = '' as $fn$
  select jsonb_build_object('format', 'crm.contacts.v1', 'source', 'manual_json',
           'source_label', 'openbrain.condo_contacts', 'include_notes', false,
           'records', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'external_id', 'condo_contacts:' || c.id,
             'given_name', nullif(btrim(c.first_name), ''),
             'family_name', nullif(btrim(c.last_name), ''),
             'emails', case when nullif(btrim(c.email), '') is not null
                            then jsonb_build_array(jsonb_build_object('value', btrim(c.email))) end,
             'phones', case when nullif(btrim(c.phone), '') is not null
                            then jsonb_build_array(jsonb_build_object('value', btrim(c.phone))) end,
             'organization', case when nullif(btrim(split_part(p.name, ' — ', 1)), '') is not null
               then jsonb_strip_nulls(jsonb_build_object(
                      'name', btrim(split_part(p.name, ' — ', 1)),
                      'title', left(case when c.relationship ~* '^\s*board\s' then btrim(c.relationship)
                                         when c.role = 'co-owner' then 'Co-owner'
                                         else initcap(nullif(btrim(c.role), '')) end, 150))) end))
             order by c.created_at, c.id), '[]'::jsonb))
    from public.condo_contacts c
    left join public.projects p on p.id = c.project_id
   where c.user_id = (select auth.uid()) and not c.archived
$fn$;

create function public.crm_build_contacts_school()
returns jsonb
language sql stable security invoker
set search_path = '' as $fn$
  select jsonb_build_object('format', 'crm.contacts.v1', 'source', 'manual_json',
           'source_label', 'openbrain.school_courses', 'include_notes', false,
           'records', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'external_id', t.external_id,
             'display_name', t.display_name,
             'emails', case when t.email is not null then jsonb_build_array(jsonb_build_object('value', t.email)) end,
             'organization', case when t.school is not null
                                  then jsonb_build_object('name', t.school, 'title', t.title) end))
             order by t.external_id), '[]'::jsonb))
    from public.crm_school_teachers() t
$fn$;

-- Minimum data only (SB-569 §3): no specialty, no notes, no title, no link to a child.
create function public.crm_build_contacts_health()
returns jsonb
language sql stable security invoker
set search_path = '' as $fn$
  select jsonb_build_object('format', 'crm.contacts.v1', 'source', 'manual_json',
           'source_label', 'openbrain.health_providers', 'include_notes', false,
           'records', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'external_id', 'health_providers:' || h.id,
             'display_name', btrim(h.name),
             'emails', case when nullif(btrim(h.email), '') is not null
                            then jsonb_build_array(jsonb_build_object('value', btrim(h.email))) end,
             'phones', case when nullif(btrim(h.phone), '') is not null
                            then jsonb_build_array(jsonb_build_object('value', btrim(h.phone))) end,
             'organization', case when nullif(btrim(h.organization), '') is not null
                                  then jsonb_build_object('name', btrim(h.organization)) end))
             order by h.created_at, h.id), '[]'::jsonb))
    from public.health_providers h
   where h.user_id = (select auth.uid()) and nullif(btrim(h.name), '') is not null
$fn$;

-- The employer's phone is the employer's, not the supervisor's, so it is not loaded.
create function public.crm_build_contacts_employers()
returns jsonb
language sql stable security invoker
set search_path = '' as $fn$
  select jsonb_build_object('format', 'crm.contacts.v1', 'source', 'manual_json',
           'source_label', 'openbrain.employer_details', 'include_notes', false,
           'records', coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'external_id', 'employer_details:' || e.id,
             'display_name', btrim(e.supervisor_name),
             'organization', case when nullif(btrim(e.employer), '') is not null
                                  then jsonb_build_object('name', btrim(e.employer), 'title', 'Supervisor') end))
             order by e.created_at, e.id), '[]'::jsonb))
    from public.employer_details e
   where e.user_id = (select auth.uid()) and nullif(btrim(e.supervisor_name), '') is not null
$fn$;

revoke all on function public.crm_build_contacts_household(jsonb) from public, anon;
revoke all on function public.crm_build_contacts_condo() from public, anon;
revoke all on function public.crm_build_contacts_school() from public, anon;
revoke all on function public.crm_build_contacts_health() from public, anon;
revoke all on function public.crm_build_contacts_employers() from public, anon;
grant execute on function public.crm_build_contacts_household(jsonb) to authenticated, service_role;
grant execute on function public.crm_build_contacts_condo() to authenticated, service_role;
grant execute on function public.crm_build_contacts_school() to authenticated, service_role;
grant execute on function public.crm_build_contacts_health() to authenticated, service_role;
grant execute on function public.crm_build_contacts_employers() to authenticated, service_role;

-- ---------------------------------------------------------------- loader internals
-- Live person an external id maps to (following a merge), or null.
create function public.crm_external_person(p_source text, p_external_id text)
returns uuid
language plpgsql stable security invoker
set search_path = '' as $fn$
declare
  v_pid  uuid;
  v_next uuid;
  v_arch boolean;
  v_hops int := 0;
begin
  select x.person_id into v_pid from public.crm_external_ids x
   where x.user_id = (select auth.uid()) and x.source = p_source and x.entity_kind = 'person'
     and x.external_id = p_external_id and not x.archived;
  loop
    exit when v_pid is null;
    select p.merged_into_id, p.archived into v_next, v_arch from public.crm_people p
     where p.id = v_pid and p.user_id = (select auth.uid());
    if not found then return null; end if;
    exit when v_next is null or v_hops >= 10;
    v_pid := v_next;
    v_hops := v_hops + 1;
  end loop;
  if v_pid is null or v_arch then return null; end if;
  return v_pid;
end $fn$;

-- Find-or-create a group by name; returns its id.
create function public.crm_loader_group(p_name text)
returns uuid
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_id uuid;
begin
  select g.id into v_id from public.crm_groups g
   where g.user_id = (select auth.uid()) and lower(g.name) = lower(p_name) and not g.archived;
  if v_id is null then
    insert into public.crm_groups (name) values (p_name) returning id into v_id;
  end if;
  return v_id;
end $fn$;

-- Find-or-create a relationship; returns 1 when a row was added.
create function public.crm_loader_relationship(p_person uuid, p_related uuid, p_type_code text, p_ref text)
returns integer
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_type uuid;
  v_n    int;
begin
  if p_person is null or p_related is null or p_person = p_related then
    return 0;
  end if;
  select t.id into v_type from public.crm_relationship_types t where t.user_id is null and t.code = p_type_code;
  insert into public.crm_person_relationships (person_id, related_person_id, relationship_type_id,
                                               source_type, source_ref, confidence)
  values (p_person, p_related, v_type, 'import', p_ref, 0.90)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

revoke all on function public.crm_external_person(text, text) from public, anon;
revoke all on function public.crm_loader_group(text) from public, anon;
revoke all on function public.crm_loader_relationship(uuid, uuid, text, text) from public, anon;
grant execute on function public.crm_external_person(text, text) to authenticated, service_role;
grant execute on function public.crm_loader_group(text) to authenticated, service_role;
grant execute on function public.crm_loader_relationship(uuid, uuid, text, text) to authenticated, service_role;

-- ---------------------------------------------------------------- household load
create function public.crm_load_household(p_owner jsonb, p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid      uuid := auth.uid();
  v_import   jsonb;
  v_owner    uuid;
  v_group    uuid;
  v_kids     uuid[];
  v_members  int := 0;
  v_rels     int := 0;
  v_confirm  int := 0;
  v_n        int;
  v_pid      uuid;
  i          int;
  j          int;
begin
  if v_uid is null then
    raise exception 'CRM load needs a signed-in owner' using errcode = '42501';
  end if;
  v_import := public.crm_import_contacts(public.crm_build_contacts_household(p_owner), p_reason);

  v_owner := public.crm_external_person('manual_json', 'household:owner');
  select coalesce(array_agg(pid order by pid), '{}') into v_kids
    from (select public.crm_external_person('manual_json', 'household:child:' || c.project_id) as pid
            from public.crm_household_children() c) k
   where pid is not null;

  v_group := public.crm_loader_group('Household');
  foreach v_pid in array (case when v_owner is null then v_kids else array[v_owner] || v_kids end) loop
    insert into public.crm_group_members (group_id, person_id) values (v_group, v_pid) on conflict do nothing;
    get diagnostics v_n = row_count;
    v_members := v_members + v_n;
  end loop;

  for i in 1 .. coalesce(array_length(v_kids, 1), 0) loop
    v_rels := v_rels + public.crm_loader_relationship(v_owner, v_kids[i], 'parent', 'manual_json:household');
    for j in i + 1 .. coalesce(array_length(v_kids, 1), 0) loop
      v_rels := v_rels + public.crm_loader_relationship(v_kids[i], v_kids[j], 'sibling', 'manual_json:household');
    end loop;
  end loop;

  foreach v_pid in array (case when v_owner is null then v_kids else array[v_owner] || v_kids end) loop
    v_confirm := v_confirm + public.crm_policy_confirm_person(v_pid, 'tier_a');
  end loop;

  return jsonb_build_object('import', v_import - 'rejected_records', 'rejected_records', v_import->'rejected_records',
                            'people', 1 + coalesce(array_length(v_kids, 1), 0) - (v_owner is null)::int,
                            'members_added', v_members, 'relationships_added', v_rels,
                            'rows_confirmed', v_confirm);
end $fn$;
comment on function public.crm_load_household(jsonb, text) is
  'SB-577 / ADR-CRM-006 §6. Household core: the owner (name passed in) and each child project, parent and '
  'sibling relationships, group Household, Tier A confirmation. Re-runnable.';

-- ---------------------------------------------------------------- internal sources load
create function public.crm_load_internal_sources(p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid      uuid := auth.uid();
  v_out      jsonb := '{}'::jsonb;
  s          record;
  v_payload  jsonb;
  v_keep     jsonb;
  v_self     jsonb;
  v_import   jsonb;
  v_group    uuid;
  v_ref      text;
  v_members  int;
  v_rels     int;
  v_selfn    int;
  v_n        int;
  rec        jsonb;
  v_pid      uuid;
  v_org      uuid;
  v_orgname  text;
  v_title    text;
  t          record;
  v_kid      uuid;
begin
  if v_uid is null then
    raise exception 'CRM load needs a signed-in owner' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'CRM load needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;

  for s in
    select * from (values
      (1, 'condo_contacts',   'Condo',  public.crm_build_contacts_condo()),
      (2, 'school_courses',   'School', public.crm_build_contacts_school()),
      (3, 'health_providers', 'Care',   public.crm_build_contacts_health()),
      (4, 'employer_details', 'Work',   public.crm_build_contacts_employers())
    ) v(ord, tbl, grp, payload)
    order by ord
  loop
    v_payload := s.payload;
    v_ref := 'manual_json:openbrain.' || s.tbl;
    v_members := 0; v_rels := 0; v_selfn := 0; v_import := null;

    -- Self-match (ADR-CRM-006 §6): an exact name match with a live household person.
    select coalesce(jsonb_agg(r) filter (where hp.id is null), '[]'::jsonb),
           coalesce(jsonb_agg(jsonb_build_object('person_id', hp.id, 'record', r)) filter (where hp.id is not null), '[]'::jsonb)
      into v_keep, v_self
      from jsonb_array_elements(v_payload->'records') r
      left join lateral (
        select p.id from public.crm_people p
         where p.user_id = v_uid and not p.archived and p.source_ref = 'manual_json:household'
           and p.name_normalized = lower(regexp_replace(btrim(coalesce(nullif(btrim(r->>'display_name'), ''),
                                         concat_ws(' ', nullif(btrim(r->>'given_name'), ''), nullif(btrim(r->>'family_name'), '')))),
                                         '\s+', ' ', 'g'))
         order by p.created_at limit 1) hp on true;

    if jsonb_array_length(v_keep) > 0 then
      v_import := public.crm_import_contacts(jsonb_set(v_payload, '{records}', v_keep), p_reason);
    end if;

    if jsonb_array_length(v_keep) + jsonb_array_length(v_self) > 0 then
      v_group := public.crm_loader_group(s.grp);
    end if;

    -- Self-matched records: the affiliation and group go on the household person.
    for rec in select value from jsonb_array_elements(v_self) loop
      v_pid := (rec->>'person_id')::uuid;
      v_orgname := nullif(btrim(rec->'record'->'organization'->>'name'), '');
      v_title := nullif(btrim(rec->'record'->'organization'->>'title'), '');
      if v_orgname is not null then
        v_org := null;
        select o.id into v_org from public.crm_organizations o
         where o.user_id = v_uid and not o.archived
           and o.name_normalized = lower(regexp_replace(v_orgname, '\s+', ' ', 'g'))
         order by o.created_at limit 1;
        if v_org is null then
          insert into public.crm_organizations (name, source_type, source_ref, confidence)
          values (v_orgname, 'import', v_ref, 0.90) returning id into v_org;
        end if;
        if not exists (select 1 from public.crm_affiliations a
                        where a.user_id = v_uid and a.person_id = v_pid and a.organization_id = v_org and not a.archived) then
          insert into public.crm_affiliations (person_id, organization_id, role_title, source_type, source_ref, confidence)
          values (v_pid, v_org, v_title, 'import', v_ref, 0.90);
        end if;
      end if;
      insert into public.crm_group_members (group_id, person_id) values (v_group, v_pid) on conflict do nothing;
      get diagnostics v_n = row_count;
      v_members := v_members + v_n;
      v_selfn := v_selfn + 1;
    end loop;

    -- Group members for every live person this source maps to.
    for rec in select value from jsonb_array_elements(v_keep) loop
      v_pid := public.crm_external_person('manual_json', rec->>'external_id');
      continue when v_pid is null;
      insert into public.crm_group_members (group_id, person_id) values (v_group, v_pid) on conflict do nothing;
      get diagnostics v_n = row_count;
      v_members := v_members + v_n;
    end loop;

    -- Teachers: relationship "teacher of" each household child they teach.
    if s.tbl = 'school_courses' then
      for t in select * from public.crm_school_teachers() loop
        v_pid := public.crm_external_person('manual_json', t.external_id);
        continue when v_pid is null;
        foreach v_kid in array coalesce(t.child_project_ids, '{}') loop
          v_rels := v_rels + public.crm_loader_relationship(
                      v_pid, public.crm_external_person('manual_json', 'household:child:' || v_kid),
                      'teacher', v_ref);
        end loop;
      end loop;
    end if;

    v_out := v_out || jsonb_build_object(s.tbl, jsonb_build_object(
               'records', jsonb_array_length(v_payload->'records'),
               'import', coalesce(v_import - 'rejected_records', 'null'::jsonb),
               'rejected_records', coalesce(v_import->'rejected_records', '[]'::jsonb),
               'self_matched', v_selfn, 'members_added', v_members, 'relationships_added', v_rels));
  end loop;
  return v_out;
end $fn$;
comment on function public.crm_load_internal_sources(text) is
  'SB-577 / ADR-CRM-006 §6. Loads condo contacts, teachers, care providers and supervisors (the caller''s rows only) '
  'through crm_import_contacts as Tier B, with groups and teacher relationships. Re-runnable.';

revoke all on function public.crm_load_household(jsonb, text) from public, anon;
revoke all on function public.crm_load_internal_sources(text) from public, anon;
grant execute on function public.crm_load_household(jsonb, text) to authenticated, service_role;
grant execute on function public.crm_load_internal_sources(text) to authenticated, service_role;

-- ---------------------------------------------------------------- assertions
do $chk$
declare
  f text;
begin
  -- A1: every new function is SECURITY INVOKER, pins search_path, and is not callable by anon.
  foreach f in array array[
    'public.crm_source_tier(text,text)', 'public.crm_policy_confirm_person(uuid,text)',
    'public.crm_household_children()', 'public.crm_school_teachers()',
    'public.crm_build_contacts_household(jsonb)', 'public.crm_build_contacts_condo()',
    'public.crm_build_contacts_school()', 'public.crm_build_contacts_health()',
    'public.crm_build_contacts_employers()', 'public.crm_external_person(text,text)',
    'public.crm_loader_group(text)', 'public.crm_loader_relationship(uuid,uuid,text,text)',
    'public.crm_load_household(jsonb,text)', 'public.crm_load_internal_sources(text)'] loop
    if (select prosecdef from pg_proc where oid = f::regprocedure) then
      raise exception 'A1: % must be SECURITY INVOKER', f;
    end if;
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and proconfig @> array['search_path=""']) then
      raise exception 'A1: % must pin search_path', f;
    end if;
    if has_function_privilege('anon', f, 'execute') then
      raise exception 'A1: anon can execute %', f;
    end if;
  end loop;

  -- A2: the decision log is RLS-protected, append-only, and closed to anon.
  if not (select relrowsecurity from pg_class where oid = 'public.crm_steward_decisions'::regclass) then
    raise exception 'A2: RLS is off on crm_steward_decisions';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.crm_steward_decisions'::regclass
                  and tgname = 'trg_crm_steward_decisions_append_only') then
    raise exception 'A2: append-only trigger missing';
  end if;
  if has_table_privilege('anon', 'public.crm_steward_decisions', 'select')
     or has_table_privilege('authenticated', 'public.crm_steward_decisions', 'update')
     or has_table_privilege('authenticated', 'public.crm_steward_decisions', 'delete') then
    raise exception 'A2: crm_steward_decisions grants are too wide';
  end if;

  -- A3: tier mapping (ADR-CRM-006 §2).
  if array[public.crm_source_tier('manual', null), public.crm_source_tier('import', 'apple_contacts:x'),
           public.crm_source_tier('import', 'vcard'), public.crm_source_tier('import', 'manual_json:household'),
           public.crm_source_tier('import', 'manual_json:openbrain.condo_contacts'),
           public.crm_source_tier('import', 'google_calendar'), public.crm_source_tier('agent', 'x'),
           public.crm_source_tier('import', 'manual_json:other')]
     <> array['A','A','A','A','B','C','C','C'] then
    raise exception 'A3: crm_source_tier mapping is wrong';
  end if;
end $chk$;
