-- SB-477 (ADR-CRM-005 §3): the canonical import contract.
--
-- One door for outside data: crm_import_contacts (crm.contacts.v1) and
-- crm_import_interactions (crm.interactions.v1). Both run as the signed-in owner
-- (SECURITY INVOKER + explicit auth.uid()), so RLS, CHECK constraints and
-- provenance always apply. Neither talks to any external system.
--
-- Idempotent: crm_external_ids remembers (source, external_id) -> entity plus a
-- hash of the last record; every write is find-or-create.
-- Never destructive: empty fields are filled and new contact points added; a
-- differing value becomes a row in crm_import_conflicts, never an overwrite, and
-- nothing is ever removed because a source stopped sending it.
-- Provenance: source_type 'import', source_ref '<source>[:<label>]', confidence
-- 0.90 (contacts) / 0.60 (interactions), unconfirmed until a human confirms.
-- Audit: one content-free bulk_import row per call.

create table public.crm_import_batches (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  source           text not null check (source in ('vcard','csv','google_contacts','outlook','apple_contacts',
                                                   'google_calendar','outlook_calendar','manual_json')),
  format           text not null check (format in ('crm.contacts.v1','crm.interactions.v1')),
  source_label     text check (char_length(source_label) <= 200),
  reason_code      text not null check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  records_received integer not null check (records_received between 0 and 1000),
  created_count    integer not null default 0,
  linked_count     integer not null default 0,
  updated_count    integer not null default 0,
  unchanged_count  integer not null default 0,
  skipped_count    integer not null default 0,
  conflict_count   integer not null default 0,
  rejected_count   integer not null default 0,
  status           text not null default 'running' check (status in ('running','completed')),
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  archived         boolean not null default false,
  archived_at      timestamptz,
  meta             jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint crm_import_batches_id_owner unique (id, user_id)
);
comment on table public.crm_import_batches is
  'SB-477 / ADR-CRM-005. One row per import call: source, counts, reason. Holds no record content.';
create index crm_import_batches_user on public.crm_import_batches (user_id, started_at desc);
select public.crm_secure_owned_table('public.crm_import_batches');

create table public.crm_external_ids (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  source         text not null check (source in ('vcard','csv','google_contacts','outlook','apple_contacts',
                                                 'google_calendar','outlook_calendar','manual_json')),
  entity_kind    text not null check (entity_kind in ('person','interaction')),
  external_id    text not null check (btrim(external_id) <> '' and char_length(external_id) <= 200),
  person_id      uuid,
  interaction_id uuid,
  first_batch_id uuid,
  last_batch_id  uuid,
  last_hash      text check (last_hash ~ '^[0-9a-f]{32}$'),
  last_seen_at   timestamptz not null default now(),
  archived       boolean not null default false,
  archived_at    timestamptz,
  meta           jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint crm_external_ids_target check (
    (entity_kind = 'person' and person_id is not null and interaction_id is null) or
    (entity_kind = 'interaction' and interaction_id is not null and person_id is null)),
  constraint crm_external_ids_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_external_ids_interaction_fk foreign key (interaction_id, user_id)
    references public.crm_interactions (id, user_id) on delete cascade
);
comment on table public.crm_external_ids is
  'SB-477 / ADR-CRM-005. (source, external_id) -> CRM entity, so a repeated import changes nothing.';
create unique index crm_external_ids_key
  on public.crm_external_ids (user_id, source, entity_kind, external_id) where not archived;
create index crm_external_ids_person on public.crm_external_ids (person_id) where person_id is not null;
create index crm_external_ids_interaction on public.crm_external_ids (interaction_id) where interaction_id is not null;
select public.crm_secure_owned_table('public.crm_external_ids');

create table public.crm_import_conflicts (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  batch_id       uuid not null,
  person_id      uuid not null,
  field          text not null check (field ~
    '^(given_name|middle_name|family_name|preferred_name|display_name|birthday|role_title@[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'),
  existing_value text not null check (char_length(existing_value) <= 200),
  incoming_value text not null check (char_length(incoming_value) <= 200),
  status         text not null default 'open' check (status in ('open','kept_existing','took_incoming','dismissed')),
  resolved_at    timestamptz,
  archived       boolean not null default false,
  archived_at    timestamptz,
  meta           jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint crm_import_conflicts_resolved check ((status = 'open') = (resolved_at is null)),
  constraint crm_import_conflicts_batch_fk foreign key (batch_id, user_id)
    references public.crm_import_batches (id, user_id) on delete cascade,
  constraint crm_import_conflicts_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);
comment on table public.crm_import_conflicts is
  'SB-477 / ADR-CRM-005. An imported value that differs from the CRM. Raised once per (person, field, incoming value), whatever its status.';
create unique index crm_import_conflicts_once
  on public.crm_import_conflicts (user_id, person_id, field, md5(incoming_value)) where not archived;
create index crm_import_conflicts_open on public.crm_import_conflicts (user_id, status);
create index crm_import_conflicts_person on public.crm_import_conflicts (person_id);
create index crm_import_conflicts_batch on public.crm_import_conflicts (batch_id);
select public.crm_secure_owned_table('public.crm_import_conflicts');

-- Validation for one crm.contacts.v1 record: an error code, or null when valid.
-- Codes only, so a rejection never echoes a value back.
create function public.crm_import_contact_error(r jsonb)
returns text
language plpgsql immutable security invoker
set search_path = '' as $fn$
declare
  k text;
  e jsonb;
  m int; d int; y int;
begin
  if r is null or jsonb_typeof(r) <> 'object' then return 'invalid_shape'; end if;
  if jsonb_typeof(r->'external_id') is distinct from 'string' or btrim(r->>'external_id') = '' then
    return 'missing_external_id';
  end if;
  if char_length(r->>'external_id') > 200 then return 'external_id_too_long'; end if;
  foreach k in array array['display_name','given_name','middle_name','family_name','preferred_name','notes'] loop
    if r ? k and jsonb_typeof(r->k) not in ('string','null') then return 'invalid_shape'; end if;
  end loop;
  if char_length(r->>'given_name') > 100 or char_length(r->>'middle_name') > 100
     or char_length(r->>'family_name') > 100 or char_length(r->>'preferred_name') > 100
     or char_length(r->>'display_name') > 200 then
    return 'name_too_long';
  end if;
  if coalesce(nullif(btrim(r->>'display_name'), ''),
              nullif(btrim(concat_ws(' ', nullif(btrim(r->>'given_name'), ''), nullif(btrim(r->>'family_name'), ''))), '')) is null then
    return 'no_name';
  end if;
  foreach k in array array['emails','phones','handles','urls'] loop
    if r ? k and r->k <> 'null'::jsonb then
      if jsonb_typeof(r->k) <> 'array' then return 'invalid_shape'; end if;
      for e in select value from jsonb_array_elements(r->k) loop
        if jsonb_typeof(e) <> 'object' or jsonb_typeof(e->'value') is distinct from 'string' or btrim(e->>'value') = '' then
          return 'invalid_shape';
        end if;
        if char_length(e->>'value') > 320 or char_length(e->>'label') > 50 then return 'value_too_long'; end if;
        if k = 'emails' and btrim(e->>'value') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
          return 'invalid_email';
        end if;
        if k = 'phones' and char_length(regexp_replace(e->>'value', '[^0-9]', '', 'g')) < 5 then
          return 'invalid_phone';
        end if;
      end loop;
    end if;
  end loop;
  if r ? 'organization' and r->'organization' <> 'null'::jsonb then
    if jsonb_typeof(r->'organization') <> 'object' then return 'invalid_shape'; end if;
    if char_length(r->'organization'->>'name') > 200 or char_length(r->'organization'->>'title') > 150
       or char_length(r->'organization'->>'department') > 150 then
      return 'value_too_long';
    end if;
  end if;
  if r ? 'birthday' and r->'birthday' <> 'null'::jsonb then
    begin
      m := (r->'birthday'->>'month')::int;
      d := (r->'birthday'->>'day')::int;
      y := (r->'birthday'->>'year')::int;
      if m is null or d is null or (y is not null and (y < 1800 or y > 2200)) then return 'invalid_birthday'; end if;
      perform make_date(coalesce(y, 2000), m, d);
    exception when others then
      return 'invalid_birthday';
    end;
  end if;
  if char_length(r->>'notes') > 4000 then return 'notes_too_long'; end if;
  return null;
end $fn$;

revoke all on function public.crm_import_contact_error(jsonb) from public, anon;
grant execute on function public.crm_import_contact_error(jsonb) to authenticated, service_role;

create function public.crm_import_contacts(p_payload jsonb, p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid       uuid := auth.uid();
  v_source    text;
  v_label     text;
  v_notes     boolean;
  v_ref       text;
  v_batch     uuid;
  v_n         int;
  rec         jsonb;
  i           int := -1;
  c_created   int := 0;
  c_linked    int := 0;
  c_updated   int := 0;
  c_unchanged int := 0;
  c_skipped   int := 0;
  c_conflicts int := 0;
  c_rejected  int := 0;
  v_rejected  jsonb := '[]'::jsonb;
  v_err       text;
  v_ext       text;
  v_hash      text;
  v_map       public.crm_external_ids%rowtype;
  v_mapped    boolean;
  v_pid       uuid;
  v_hops      int;
  v_person    public.crm_people%rowtype;
  v_outcome   text;
  v_changed   boolean;
  v_matches   uuid[];
  v_emails    text[];
  v_phones    text[];
  v_display   text;
  f           record;
  pt          record;
  v_orgname   text;
  v_org       uuid;
  v_title     text;
  v_dept      text;
  v_aff       public.crm_affiliations%rowtype;
  v_m         int;
  v_d         int;
  v_y         int;
  v_bd        public.crm_important_dates%rowtype;
  v_note      text;
  v_ins       int;
begin
  if v_uid is null then
    raise exception 'CRM import needs a signed-in owner' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'CRM import needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or (p_payload->>'format') is distinct from 'crm.contacts.v1' then
    raise exception 'unsupported import format (expected crm.contacts.v1)' using errcode = '22023';
  end if;
  v_source := p_payload->>'source';
  if v_source is null or v_source not in ('vcard','csv','google_contacts','outlook','apple_contacts','manual_json') then
    raise exception 'unknown contact import source %', coalesce(v_source, '(null)') using errcode = '22023';
  end if;
  v_label := nullif(btrim(p_payload->>'source_label'), '');
  if char_length(v_label) > 200 then
    raise exception 'source_label is longer than 200 characters' using errcode = '22023';
  end if;
  if jsonb_typeof(p_payload->'records') is distinct from 'array' then
    raise exception 'records must be an array' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_payload->'records');
  if v_n > 1000 then
    raise exception 'at most 1000 records per call (got %)', v_n using errcode = '22023';
  end if;
  v_notes := coalesce(p_payload->'include_notes' = 'true'::jsonb, false);
  v_ref := v_source || coalesce(':' || v_label, '');

  insert into public.crm_import_batches (source, format, source_label, reason_code, records_received)
  values (v_source, 'crm.contacts.v1', v_label, p_reason, v_n)
  returning id into v_batch;

  for rec in select value from jsonb_array_elements(p_payload->'records') loop
    i := i + 1;
    v_err := public.crm_import_contact_error(rec);
    if v_err is not null then
      c_rejected := c_rejected + 1;
      v_rejected := v_rejected || jsonb_build_object('index', i, 'error', v_err);
      continue;
    end if;

    begin
      v_ext := btrim(rec->>'external_id');
      v_hash := md5(rec::text);
      v_changed := false;
      v_outcome := null;
      v_display := coalesce(nullif(btrim(rec->>'display_name'), ''),
                            btrim(concat_ws(' ', nullif(btrim(rec->>'given_name'), ''), nullif(btrim(rec->>'family_name'), ''))));
      v_emails := array(select lower(btrim(x->>'value'))
                          from jsonb_array_elements(coalesce(nullif(rec->'emails', 'null'::jsonb), '[]'::jsonb)) x);
      v_phones := array(select regexp_replace(x->>'value', '[^0-9+]', '', 'g')
                          from jsonb_array_elements(coalesce(nullif(rec->'phones', 'null'::jsonb), '[]'::jsonb)) x);

      select * into v_map from public.crm_external_ids x
       where x.user_id = v_uid and x.source = v_source and x.entity_kind = 'person'
         and x.external_id = v_ext and not x.archived;
      v_mapped := found;

      if v_mapped then
        if v_map.last_hash = v_hash then
          update public.crm_external_ids set last_batch_id = v_batch, last_seen_at = now() where id = v_map.id;
          c_unchanged := c_unchanged + 1;
          continue;
        end if;
        -- Follow a reviewed merge to the person that was kept.
        v_pid := v_map.person_id;
        v_hops := 0;
        loop
          select * into v_person from public.crm_people p where p.id = v_pid and p.user_id = v_uid;
          exit when v_person.id is null or v_person.merged_into_id is null or v_hops >= 10;
          v_pid := v_person.merged_into_id;
          v_hops := v_hops + 1;
        end loop;
        if v_person.id is null or v_person.archived then
          -- The owner archived this person: an import never brings it back.
          update public.crm_external_ids
             set last_batch_id = v_batch, last_seen_at = now(), last_hash = v_hash
           where id = v_map.id;
          c_skipped := c_skipped + 1;
          continue;
        end if;
        v_outcome := 'mapped';
      else
        select array_agg(distinct cp.person_id) into v_matches
          from public.crm_contact_points cp
          join public.crm_people p on p.id = cp.person_id and p.user_id = v_uid
         where cp.user_id = v_uid and not cp.archived and not p.archived
           and ((cp.kind = 'email' and cp.value_normalized = any(v_emails))
             or (cp.kind = 'phone' and cp.value_normalized = any(v_phones)));
        if coalesce(array_length(v_matches, 1), 0) = 1 then
          v_pid := v_matches[1];
          select * into v_person from public.crm_people p where p.id = v_pid and p.user_id = v_uid;
          v_outcome := 'linked';
        else
          -- No match, or more than one: never guess (ADR-CRM-005 §3.4).
          insert into public.crm_people (display_name, given_name, middle_name, family_name, preferred_name,
                                         source_type, source_ref, confidence)
          values (v_display, nullif(btrim(rec->>'given_name'), ''), nullif(btrim(rec->>'middle_name'), ''),
                  nullif(btrim(rec->>'family_name'), ''), nullif(btrim(rec->>'preferred_name'), ''),
                  'import', v_ref, 0.90)
          returning * into v_person;
          v_pid := v_person.id;
          v_outcome := 'created';
        end if;
        insert into public.crm_external_ids (source, entity_kind, external_id, person_id,
                                             first_batch_id, last_batch_id, last_hash)
        values (v_source, 'person', v_ext, v_pid, v_batch, v_batch, v_hash);
      end if;

      -- Names: fill what is empty; a differing value is a conflict, never an overwrite.
      if v_outcome <> 'created' then
        for f in
          select t.field, t.existing, t.incoming from (values
            ('given_name',     v_person.given_name,     nullif(btrim(rec->>'given_name'), '')),
            ('middle_name',    v_person.middle_name,    nullif(btrim(rec->>'middle_name'), '')),
            ('family_name',    v_person.family_name,    nullif(btrim(rec->>'family_name'), '')),
            ('preferred_name', v_person.preferred_name, nullif(btrim(rec->>'preferred_name'), '')),
            ('display_name',   v_person.display_name,   nullif(btrim(rec->>'display_name'), ''))
          ) t(field, existing, incoming)
        loop
          continue when f.incoming is null;
          if f.existing is null then
            execute format('update public.crm_people set %I = $1 where id = $2 and user_id = $3', f.field)
              using f.incoming, v_pid, v_uid;
            v_changed := true;
          elsif lower(f.existing) <> lower(f.incoming) then
            insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
            values (v_batch, v_pid, f.field, f.existing, f.incoming)
            on conflict (user_id, person_id, field, md5(incoming_value)) where not archived do nothing;
            get diagnostics v_ins = row_count;
            c_conflicts := c_conflicts + v_ins;
          end if;
        end loop;
      end if;

      -- Contact points: add the missing ones; never change or remove an existing one.
      for pt in
        select k.kind, btrim(x->>'value') as value, left(nullif(btrim(x->>'label'), ''), 50) as label,
               coalesce(x->'preferred' = 'true'::jsonb, false) as preferred
          from (values ('email','emails'), ('phone','phones'), ('handle','handles'), ('url','urls')) k(kind, key)
          cross join lateral jsonb_array_elements(coalesce(nullif(rec->k.key, 'null'::jsonb), '[]'::jsonb)) x
      loop
        insert into public.crm_contact_points (person_id, kind, label, value, is_preferred,
                                               source_type, source_ref, confidence)
        values (v_pid, pt.kind, pt.label, pt.value,
                pt.preferred and not exists (select 1 from public.crm_contact_points y
                                              where y.person_id = v_pid and y.user_id = v_uid and y.kind = pt.kind
                                                and y.is_preferred and not y.archived),
                'import', v_ref, 0.90)
        on conflict (person_id, kind, value_normalized) do nothing;
        get diagnostics v_ins = row_count;
        if v_ins > 0 then v_changed := true; end if;
      end loop;

      -- Organization and role.
      v_orgname := nullif(btrim(rec->'organization'->>'name'), '');
      if v_orgname is not null then
        v_title := nullif(btrim(rec->'organization'->>'title'), '');
        v_dept := nullif(btrim(rec->'organization'->>'department'), '');
        select o.id into v_org from public.crm_organizations o
         where o.user_id = v_uid and not o.archived
           and o.name_normalized = lower(regexp_replace(v_orgname, '\s+', ' ', 'g'))
         order by o.created_at limit 1;
        if v_org is null then
          insert into public.crm_organizations (name, source_type, source_ref, confidence)
          values (v_orgname, 'import', v_ref, 0.90)
          returning id into v_org;
          v_changed := true;
        end if;
        select * into v_aff from public.crm_affiliations a
         where a.user_id = v_uid and a.person_id = v_pid and a.organization_id = v_org and not a.archived
         order by a.created_at limit 1;
        if v_aff.id is null then
          insert into public.crm_affiliations (person_id, organization_id, role_title, department,
                                               source_type, source_ref, confidence)
          values (v_pid, v_org, v_title, v_dept, 'import', v_ref, 0.90);
          v_changed := true;
        elsif v_title is not null then
          if v_aff.role_title is null then
            update public.crm_affiliations set role_title = v_title where id = v_aff.id and user_id = v_uid;
            v_changed := true;
          elsif lower(v_aff.role_title) <> lower(v_title) then
            insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
            values (v_batch, v_pid, 'role_title@' || v_org, v_aff.role_title, v_title)
            on conflict (user_id, person_id, field, md5(incoming_value)) where not archived do nothing;
            get diagnostics v_ins = row_count;
            c_conflicts := c_conflicts + v_ins;
          end if;
        end if;
      end if;

      -- Birthday.
      if rec ? 'birthday' and rec->'birthday' <> 'null'::jsonb then
        v_m := (rec->'birthday'->>'month')::int;
        v_d := (rec->'birthday'->>'day')::int;
        v_y := (rec->'birthday'->>'year')::int;
        select * into v_bd from public.crm_important_dates x
         where x.user_id = v_uid and x.person_id = v_pid and x.kind = 'birthday' and not x.archived
         order by x.created_at limit 1;
        if v_bd.id is null then
          insert into public.crm_important_dates (person_id, kind, month, day, year, source_type, source_ref, confidence)
          values (v_pid, 'birthday', v_m, v_d, v_y, 'import', v_ref, 0.90);
          v_changed := true;
        elsif v_bd.month = v_m and v_bd.day = v_d and (v_y is null or v_bd.year = v_y) then
          null;
        elsif v_bd.month = v_m and v_bd.day = v_d and v_bd.year is null then
          update public.crm_important_dates set year = v_y where id = v_bd.id and user_id = v_uid;
          v_changed := true;
        else
          insert into public.crm_import_conflicts (batch_id, person_id, field, existing_value, incoming_value)
          values (v_batch, v_pid, 'birthday',
                  lpad(v_bd.month::text, 2, '0') || '-' || lpad(v_bd.day::text, 2, '0') || coalesce('-' || v_bd.year, ''),
                  lpad(v_m::text, 2, '0') || '-' || lpad(v_d::text, 2, '0') || coalesce('-' || v_y, ''))
          on conflict (user_id, person_id, field, md5(incoming_value)) where not archived do nothing;
          get diagnostics v_ins = row_count;
          c_conflicts := c_conflicts + v_ins;
        end if;
      end if;

      -- Notes, only when the payload asks for them; same text is never added twice.
      v_note := nullif(btrim(rec->>'notes'), '');
      if v_notes and v_note is not null
         and not exists (select 1 from public.crm_facts x
                          where x.user_id = v_uid and x.person_id = v_pid and x.fact_type = 'imported_note'
                            and x.value = v_note and not x.archived) then
        insert into public.crm_facts (person_id, fact_type, value, source_type, source_ref, confidence)
        values (v_pid, 'imported_note', v_note, 'import', v_ref, 0.90);
        v_changed := true;
      end if;

      if v_outcome = 'created' then
        c_created := c_created + 1;
      elsif v_outcome = 'linked' then
        c_linked := c_linked + 1;
      elsif v_changed then
        c_updated := c_updated + 1;
      else
        c_unchanged := c_unchanged + 1;
      end if;
      if v_outcome = 'mapped' then
        update public.crm_external_ids
           set person_id = v_pid, last_hash = v_hash, last_batch_id = v_batch, last_seen_at = now()
         where id = v_map.id;
      end if;
    exception when others then
      -- One bad record never costs the batch; report the code, never the value.
      c_rejected := c_rejected + 1;
      v_rejected := v_rejected || jsonb_build_object('index', i, 'error', 'failed_' || sqlstate);
    end;
  end loop;

  update public.crm_import_batches
     set created_count = c_created, linked_count = c_linked, updated_count = c_updated,
         unchanged_count = c_unchanged, skipped_count = c_skipped, conflict_count = c_conflicts,
         rejected_count = c_rejected, status = 'completed', finished_at = now()
   where id = v_batch;
  perform public.crm_audit('bulk_import', 'crm_import_batches', v_batch, v_n, 'succeeded', p_reason, null, v_uid);

  return jsonb_build_object('batch_id', v_batch, 'received', v_n, 'created', c_created, 'linked', c_linked,
                            'updated', c_updated, 'unchanged', c_unchanged, 'skipped', c_skipped,
                            'conflicts', c_conflicts, 'rejected', c_rejected, 'rejected_records', v_rejected);
end $fn$;

revoke all on function public.crm_import_contacts(jsonb, text) from public, anon;
grant execute on function public.crm_import_contacts(jsonb, text) to authenticated, service_role;

create function public.crm_import_interactions(p_payload jsonb, p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid       uuid := auth.uid();
  v_source    text;
  v_label     text;
  v_ref       text;
  v_batch     uuid;
  v_n         int;
  rec         jsonb;
  i           int := -1;
  c_created   int := 0;
  c_updated   int := 0;
  c_unchanged int := 0;
  c_skipped   int := 0;
  c_rejected  int := 0;
  v_rejected  jsonb := '[]'::jsonb;
  v_err       text;
  v_ext       text;
  v_hash      text;
  v_map       public.crm_external_ids%rowtype;
  v_type      text;
  v_at        timestamptz;
  v_end       timestamptz;
  v_title     text;
  v_loc       text;
  v_people    uuid[];
  v_iid       uuid;
  v_conf      timestamptz;
  v_arch      boolean;
  v_ins       int;
  v_touched   int;
begin
  if v_uid is null then
    raise exception 'CRM import needs a signed-in owner' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'CRM import needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or (p_payload->>'format') is distinct from 'crm.interactions.v1' then
    raise exception 'unsupported import format (expected crm.interactions.v1)' using errcode = '22023';
  end if;
  v_source := p_payload->>'source';
  if v_source is null or v_source not in ('google_calendar','outlook_calendar','manual_json') then
    raise exception 'unknown interaction import source %', coalesce(v_source, '(null)') using errcode = '22023';
  end if;
  v_label := nullif(btrim(p_payload->>'source_label'), '');
  if char_length(v_label) > 200 then
    raise exception 'source_label is longer than 200 characters' using errcode = '22023';
  end if;
  if jsonb_typeof(p_payload->'records') is distinct from 'array' then
    raise exception 'records must be an array' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_payload->'records');
  if v_n > 1000 then
    raise exception 'at most 1000 records per call (got %)', v_n using errcode = '22023';
  end if;
  v_ref := v_source || coalesce(':' || v_label, '');

  insert into public.crm_import_batches (source, format, source_label, reason_code, records_received)
  values (v_source, 'crm.interactions.v1', v_label, p_reason, v_n)
  returning id into v_batch;

  for rec in select value from jsonb_array_elements(p_payload->'records') loop
    i := i + 1;
    v_err := null;
    if jsonb_typeof(rec) is distinct from 'object' then
      v_err := 'invalid_shape';
    elsif jsonb_typeof(rec->'external_id') is distinct from 'string' or btrim(rec->>'external_id') = '' then
      v_err := 'missing_external_id';
    elsif char_length(rec->>'external_id') > 200 then
      v_err := 'external_id_too_long';
    elsif coalesce(rec->>'interaction_type', 'meeting') not in
          ('call','meeting','email','message','meal','event','gift','introduction','note','other') then
      v_err := 'invalid_type';
    elsif char_length(rec->>'title') > 200 or char_length(rec->>'location') > 200 then
      v_err := 'value_too_long';
    elsif rec ? 'participant_emails' and jsonb_typeof(rec->'participant_emails') not in ('array','null') then
      v_err := 'invalid_shape';
    end if;
    if v_err is null then
      begin
        v_at := (rec->>'occurred_at')::timestamptz;
        v_end := (rec->>'ended_at')::timestamptz;
      exception when others then
        v_err := 'invalid_time';
      end;
      if v_err is null and (v_at is null or (v_end is not null and v_end < v_at)) then
        v_err := 'invalid_time';
      end if;
    end if;
    if v_err is not null then
      c_rejected := c_rejected + 1;
      v_rejected := v_rejected || jsonb_build_object('index', i, 'error', v_err);
      continue;
    end if;

    begin
      v_ext := btrim(rec->>'external_id');
      v_hash := md5(rec::text);
      v_type := coalesce(rec->>'interaction_type', 'meeting');
      v_title := nullif(btrim(rec->>'title'), '');
      v_loc := nullif(btrim(rec->>'location'), '');
      -- An email counts only when it identifies exactly one live person. Nobody is
      -- ever created from an attendee, and unmatched addresses are not stored.
      select array_agg(distinct s.pid) into v_people
        from (select (array_agg(distinct cp.person_id))[1] as pid
                from public.crm_contact_points cp
                join public.crm_people p on p.id = cp.person_id and p.user_id = v_uid
               where cp.user_id = v_uid and cp.kind = 'email' and not cp.archived and not p.archived
                 and cp.value_normalized = any(array(
                       select lower(btrim(x))
                         from jsonb_array_elements_text(coalesce(nullif(rec->'participant_emails', 'null'::jsonb), '[]'::jsonb)) x))
               group by cp.value_normalized
              having count(distinct cp.person_id) = 1) s;

      select * into v_map from public.crm_external_ids x
       where x.user_id = v_uid and x.source = v_source and x.entity_kind = 'interaction'
         and x.external_id = v_ext and not x.archived;

      if found then
        if v_map.last_hash = v_hash then
          update public.crm_external_ids set last_batch_id = v_batch, last_seen_at = now() where id = v_map.id;
          c_unchanged := c_unchanged + 1;
          continue;
        end if;
        v_iid := v_map.interaction_id;
        select confirmed_at, archived into v_conf, v_arch
          from public.crm_interactions where id = v_iid and user_id = v_uid;
        if not found or v_arch then
          update public.crm_external_ids set last_batch_id = v_batch, last_seen_at = now(), last_hash = v_hash
           where id = v_map.id;
          c_skipped := c_skipped + 1;
          continue;
        end if;
        v_touched := 0;
        if v_conf is null then
          -- Still the source's own unconfirmed copy: follow the source (a moved meeting).
          update public.crm_interactions
             set interaction_type = v_type, occurred_at = v_at, ended_at = v_end, title = v_title, location = v_loc
           where id = v_iid and user_id = v_uid
             and (interaction_type, occurred_at, ended_at, title, location)
                 is distinct from (v_type, v_at, v_end, v_title, v_loc);
          get diagnostics v_touched = row_count;
        end if;
        -- A human-confirmed interaction is left as the human left it, except that
        -- newly matched participants are added (nothing is ever removed).
        insert into public.crm_interaction_participants (interaction_id, person_id)
        select v_iid, u.pid from unnest(coalesce(v_people, '{}'::uuid[])) u(pid)
         where not exists (select 1 from public.crm_interaction_participants ip
                            where ip.interaction_id = v_iid and ip.person_id = u.pid and not ip.archived);
        get diagnostics v_ins = row_count;
        if v_touched + v_ins > 0 then c_updated := c_updated + 1; else c_unchanged := c_unchanged + 1; end if;
        update public.crm_external_ids set last_hash = v_hash, last_batch_id = v_batch, last_seen_at = now()
         where id = v_map.id;
      else
        if coalesce(array_length(v_people, 1), 0) = 0 then
          -- Nobody we know was there. Not recorded, so a later import can still
          -- create it once one of the attendees exists in the CRM.
          c_skipped := c_skipped + 1;
          continue;
        end if;
        insert into public.crm_interactions (interaction_type, occurred_at, ended_at, title, location,
                                             source_type, source_ref, confidence)
        values (v_type, v_at, v_end, v_title, v_loc, 'import', v_ref, 0.60)
        returning id into v_iid;
        insert into public.crm_interaction_participants (interaction_id, person_id)
        select v_iid, u.pid from unnest(v_people) u(pid);
        insert into public.crm_external_ids (source, entity_kind, external_id, interaction_id,
                                             first_batch_id, last_batch_id, last_hash)
        values (v_source, 'interaction', v_ext, v_iid, v_batch, v_batch, v_hash);
        c_created := c_created + 1;
      end if;
    exception when others then
      c_rejected := c_rejected + 1;
      v_rejected := v_rejected || jsonb_build_object('index', i, 'error', 'failed_' || sqlstate);
    end;
  end loop;

  update public.crm_import_batches
     set created_count = c_created, updated_count = c_updated, unchanged_count = c_unchanged,
         skipped_count = c_skipped, rejected_count = c_rejected, status = 'completed', finished_at = now()
   where id = v_batch;
  perform public.crm_audit('bulk_import', 'crm_import_batches', v_batch, v_n, 'succeeded', p_reason, null, v_uid);

  return jsonb_build_object('batch_id', v_batch, 'received', v_n, 'created', c_created, 'updated', c_updated,
                            'unchanged', c_unchanged, 'skipped', c_skipped, 'rejected', c_rejected,
                            'rejected_records', v_rejected);
end $fn$;

revoke all on function public.crm_import_interactions(jsonb, text) from public, anon;
grant execute on function public.crm_import_interactions(jsonb, text) to authenticated, service_role;

create function public.crm_resolve_import_conflict(p_conflict_id uuid, p_resolution text)
returns text
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  c     public.crm_import_conflicts%rowtype;
  v_org uuid;
  v_m   int;
  v_d   int;
  v_y   int;
  v_n   int := 0;
begin
  if v_uid is null then
    raise exception 'resolving an import conflict needs a signed-in owner' using errcode = '42501';
  end if;
  if p_resolution is null or p_resolution not in ('kept_existing','took_incoming','dismissed') then
    raise exception 'resolution must be kept_existing, took_incoming or dismissed' using errcode = '22023';
  end if;
  select * into c from public.crm_import_conflicts x
   where x.id = p_conflict_id and x.user_id = v_uid and not x.archived
   for update;
  if not found then
    raise exception 'import conflict not found' using errcode = 'P0002';
  end if;
  if c.status <> 'open' then
    raise exception 'import conflict is already %', c.status using errcode = '22023';
  end if;

  if p_resolution = 'took_incoming' then
    -- A person chose the incoming value: it is written as a confirmed edit.
    if c.field in ('given_name','middle_name','family_name','preferred_name','display_name') then
      execute format('update public.crm_people set %I = $1, confirmed_at = coalesce(confirmed_at, now())
                       where id = $2 and user_id = $3 and not archived', c.field)
        using c.incoming_value, c.person_id, v_uid;
      get diagnostics v_n = row_count;
    elsif c.field = 'birthday' then
      v_m := split_part(c.incoming_value, '-', 1)::int;
      v_d := split_part(c.incoming_value, '-', 2)::int;
      v_y := nullif(split_part(c.incoming_value, '-', 3), '')::int;
      update public.crm_important_dates
         set month = v_m, day = v_d, year = v_y, confirmed_at = coalesce(confirmed_at, now())
       where id = (select x.id from public.crm_important_dates x
                    where x.user_id = v_uid and x.person_id = c.person_id and x.kind = 'birthday' and not x.archived
                    order by x.created_at limit 1);
      get diagnostics v_n = row_count;
    elsif c.field like 'role_title@%' then
      v_org := substr(c.field, 12)::uuid;
      update public.crm_affiliations
         set role_title = c.incoming_value, confirmed_at = coalesce(confirmed_at, now())
       where id = (select a.id from public.crm_affiliations a
                    where a.user_id = v_uid and a.person_id = c.person_id and a.organization_id = v_org and not a.archived
                    order by a.created_at limit 1);
      get diagnostics v_n = row_count;
    end if;
    if v_n = 0 then
      raise exception 'the record this conflict refers to no longer exists' using errcode = 'P0002';
    end if;
  end if;

  update public.crm_import_conflicts set status = p_resolution, resolved_at = now() where id = c.id;
  return p_resolution;
end $fn$;

revoke all on function public.crm_resolve_import_conflict(uuid, text) from public, anon;
grant execute on function public.crm_resolve_import_conflict(uuid, text) to authenticated, service_role;

do $chk$
declare n int;
begin
  -- A1: the three tables meet the owned-table standard (RLS, owner policies, grants, triggers)
  perform public.crm_assert_owned_table('public.crm_import_batches');
  perform public.crm_assert_owned_table('public.crm_external_ids');
  perform public.crm_assert_owned_table('public.crm_import_conflicts');
  -- A2: the four functions run with the caller's rights; authenticated can run them, anon cannot
  select count(*) into n from pg_proc p
   where p.oid in ('public.crm_import_contact_error(jsonb)'::regprocedure,
                   'public.crm_import_contacts(jsonb,text)'::regprocedure,
                   'public.crm_import_interactions(jsonb,text)'::regprocedure,
                   'public.crm_resolve_import_conflict(uuid,text)'::regprocedure)
     and not p.prosecdef and has_function_privilege('authenticated', p.oid, 'execute')
     and not has_function_privilege('anon', p.oid, 'execute');
  if n <> 4 then raise exception 'A2: % of 4 import functions are invoker + authenticated-only', n; end if;
  -- A3: no CRM function talks to the network (ADR-CRM-005 §2.2: no connector in this epic)
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosrc ilike '%net.http%';
  if n > 0 then raise exception 'A3: % crm_ function(s) reference net.http', n; end if;
  -- A4: the agent surface is unchanged (ADR-CRM-004 §2.1)
  if (select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'public' and p.proname like 'crm\_%\_for\_agent')
     <> array['crm_facts_for_agent','crm_interactions_for_agent','crm_person_card_for_agent']::name[] then
    raise exception 'A4: the *_for_agent set changed';
  end if;
  -- A5: the validator accepts a good record and names each bad one by code
  if public.crm_import_contact_error('{"external_id":"x1","given_name":"Ana","emails":[{"value":"a@b.example"}],"birthday":{"month":2,"day":29}}') is not null
     or public.crm_import_contact_error('{"given_name":"Ana"}') <> 'missing_external_id'
     or public.crm_import_contact_error('{"external_id":"x","emails":[{"value":"nope"}],"given_name":"A"}') <> 'invalid_email'
     or public.crm_import_contact_error('{"external_id":"x","given_name":"A","birthday":{"month":2,"day":30}}') <> 'invalid_birthday'
     or public.crm_import_contact_error('{"external_id":"x"}') <> 'no_name' then
    raise exception 'A5: crm_import_contact_error does not classify the reference records';
  end if;
end $chk$;
