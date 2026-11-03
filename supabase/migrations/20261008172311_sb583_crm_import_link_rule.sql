-- SB-583 (amends ADR-CRM-005 §3.4 and ADR-CRM-006 §4): an email is identity, a phone is only a clue.
--
-- Found in the 2026-10-07 Apple Contacts load: 3 of 26 links joined different people who shared one
-- phone (an office main line, a household landline, a family number abroad). crm_import_contacts now
-- links on a unique email match; only when no email matches does a shared phone link, and then only to
-- a person whose given name is compatible. crm_steward_run's auto_merge_contact rule gets the same
-- guard, because a shared phone plus the same surname would have re-merged two relatives.
-- Bodies are the SB-477 / SB-573 functions with only the marked blocks changed.

-- ---------------------------------------------------------------- name helpers
create or replace function public.crm_name_tokens(p_given text, p_preferred text, p_display text)
returns text[]
language sql immutable parallel safe
set search_path = '' as $fn$
  select coalesce(array_agg(distinct t order by t), '{}'::text[])
    from regexp_split_to_table(
           lower(coalesce(nullif(btrim(p_given), ''), split_part(btrim(coalesce(p_display, '')), ' ', 1))
                 || ' ' || coalesce(p_preferred, '')),
           '[^[:alpha:]]+') as t
   where char_length(t) >= 2
     and t not in ('dr', 'mr', 'mrs', 'ms', 'miss', 'prof', 'sir', 'jr', 'sr');
$fn$;
comment on function public.crm_name_tokens(text, text, text) is
  'SB-583. Lowercased given and preferred name tokens (first word of display when given is empty); titles dropped.';

create or replace function public.crm_given_names_compatible(a text[], b text[])
returns boolean
language sql immutable parallel safe
set search_path = '' as $fn$
  select exists (
    select 1 from unnest(coalesce(a, '{}'::text[])) x, unnest(coalesce(b, '{}'::text[])) y
     where x = y
        or (least(char_length(x), char_length(y)) >= 3 and (strpos(y, x) = 1 or strpos(x, y) = 1)));
$fn$;
comment on function public.crm_given_names_compatible(text[], text[]) is
  'SB-583. True when two given-name token sets share a token, or a 3+ letter token prefixes the other (alex/alexander).';

revoke all on function public.crm_name_tokens(text, text, text) from public, anon;
revoke all on function public.crm_given_names_compatible(text[], text[]) from public, anon;
grant execute on function public.crm_name_tokens(text, text, text) to authenticated, service_role;
grant execute on function public.crm_given_names_compatible(text[], text[]) to authenticated, service_role;

-- ---------------------------------------------------------------- import: matching (§3.4)
create or replace function public.crm_import_contacts(p_payload jsonb, p_reason text)
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
  v_tokens    text[];
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
        -- SB-583 (ADR-CRM-005 §3.4 as amended): an email is identity, a phone is only a clue.
        select array_agg(distinct cp.person_id) into v_matches
          from public.crm_contact_points cp
          join public.crm_people p on p.id = cp.person_id and p.user_id = v_uid
         where cp.user_id = v_uid and not cp.archived and not p.archived
           and cp.kind = 'email' and cp.value_normalized = any(v_emails);
        if coalesce(array_length(v_matches, 1), 0) = 0 then
          -- No email matched: a shared phone links only to someone whose given name fits.
          v_tokens := public.crm_name_tokens(rec->>'given_name', rec->>'preferred_name', v_display);
          select array_agg(distinct cp.person_id) into v_matches
            from public.crm_contact_points cp
            join public.crm_people p on p.id = cp.person_id and p.user_id = v_uid
           where cp.user_id = v_uid and not cp.archived and not p.archived
             and cp.kind = 'phone' and cp.value_normalized = any(v_phones)
             and public.crm_given_names_compatible(
                   v_tokens, public.crm_name_tokens(p.given_name, p.preferred_name, p.display_name));
        end if;
        if coalesce(array_length(v_matches, 1), 0) = 1 then
          v_pid := v_matches[1];
          select * into v_person from public.crm_people p where p.id = v_pid and p.user_id = v_uid;
          v_outcome := 'linked';
        else
          -- No match, more than one, or a phone without a fitting name: never guess (ADR-CRM-005 §3.4).
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

-- ---------------------------------------------------------------- steward: auto_merge_contact
create or replace function public.crm_steward_run(p_dry_run boolean default false, p_limit integer default 200)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid       uuid := auth.uid();
  v_lim       int := least(greatest(coalesce(p_limit, 200), 1), 200);
  v_run       uuid := gen_random_uuid();
  v_enabled   boolean;
  v_suspended boolean;
  v_n         int := 0;     -- decisions made this run
  -- counters
  c_took int := 0; c_kept int := 0; c_left_aa int := 0; c_res_err int := 0;
  c_merged int := 0; c_merge_err int := 0;
  c_dismissed int := 0; c_gray_left int := 0;
  c_conf_a int := 0; c_conf_b int := 0; c_conf_c int := 0;
  c_exp_f int := 0; c_exp_i int := 0;
  v_summary   jsonb;
  -- work
  ic          record;
  cand        record;
  pa          public.crm_people%rowtype;
  pb          public.crm_people%rowtype;
  v_exist     text;
  v_in        text;
  v_res       text;
  v_rule      text;
  v_keep      uuid;
  v_merge     uuid;
  v_log       uuid;
  v_dis       uuid;
  v_k         int;
  v_dups      uuid[];
  r           record;
  names_ok    boolean;
  by_email    boolean;
  by_phone    boolean;
begin
  if v_uid is null then
    raise exception 'the steward run needs a signed-in owner' using errcode = '42501';
  end if;
  select exists (select 1 from public.agents a
                  where a.user_id = v_uid and a.name = 'CRM Data Steward'
                    and a.automation_enabled and coalesce(a.status, 'active') = 'active')
    into v_enabled;
  if not coalesce(p_dry_run, false) and not v_enabled then
    return jsonb_build_object('disabled', true, 'dry_run', false,
                              'reason', 'no active CRM Data Steward agent with automation enabled');
  end if;
  v_suspended := coalesce((select d.decision = 'suspend' from public.crm_steward_decisions d
                            where d.user_id = v_uid and d.decision in ('suspend', 'resume')
                            order by d.created_at desc, d.id desc limit 1), false);

  begin  -- a dry run does everything here, then rolls this block back
    perform set_config('crm.steward_run_id', v_run::text, true);

    -- ---------------------------------------------- 1. import conflicts by tier (§5)
    for ic in
      select c.*, b.source, b.source_label
        from public.crm_import_conflicts c
        join public.crm_import_batches b on b.id = c.batch_id and b.user_id = c.user_id
       where c.user_id = v_uid and c.status = 'open' and not c.archived
       order by c.created_at, c.id
    loop
      exit when v_n >= v_lim;
      v_exist := null;
      if ic.field in ('given_name','middle_name','family_name','preferred_name','display_name') then
        select public.crm_source_tier(p.source_type, p.source_ref) into v_exist
          from public.crm_people p where p.id = ic.person_id and p.user_id = v_uid;
      elsif ic.field = 'birthday' then
        select public.crm_source_tier(d.source_type, d.source_ref) into v_exist
          from public.crm_important_dates d
         where d.user_id = v_uid and d.person_id = ic.person_id and d.kind = 'birthday' and not d.archived
         order by d.created_at limit 1;
      elsif ic.field like 'role_title@%' then
        select public.crm_source_tier(a.source_type, a.source_ref) into v_exist
          from public.crm_affiliations a
         where a.user_id = v_uid and a.person_id = ic.person_id
           and a.organization_id = substr(ic.field, 12)::uuid and not a.archived
         order by a.created_at limit 1;
      end if;
      continue when v_exist is null;
      v_in := public.crm_source_tier('import', ic.source || coalesce(':' || ic.source_label, ''));
      if v_exist = 'A' and v_in = 'A' then
        c_left_aa := c_left_aa + 1;
        continue;
      end if;
      if position(v_in in 'CBA') > position(v_exist in 'CBA') then
        v_res := 'took_incoming'; v_rule := 'auto_resolve_higher_tier';
      elsif position(v_in in 'CBA') < position(v_exist in 'CBA') then
        v_res := 'kept_existing'; v_rule := 'auto_resolve_lower_tier';
      elsif ic.field like 'role_title@%' then
        v_res := 'took_incoming'; v_rule := 'auto_resolve_newer';
      elsif ic.field = 'birthday' then
        v_res := 'kept_existing'; v_rule := 'auto_resolve_keep_date';
      else
        v_res := 'kept_existing'; v_rule := 'auto_resolve_keep_name';
      end if;
      begin
        perform public.crm_resolve_import_conflict(ic.id, v_res);
      exception when others then
        c_res_err := c_res_err + 1;
        continue;
      end;
      if v_res = 'took_incoming' then
        if ic.field like 'role_title@%' then
          update public.crm_affiliations set meta = meta || '{"confirmed_by":"policy:auto_resolve"}'
           where id = (select a.id from public.crm_affiliations a
                        where a.user_id = v_uid and a.person_id = ic.person_id
                          and a.organization_id = substr(ic.field, 12)::uuid and not a.archived
                        order by a.created_at limit 1);
        else
          update public.crm_people set meta = meta || '{"confirmed_by":"policy:auto_resolve"}'
           where id = ic.person_id and user_id = v_uid;
        end if;
        c_took := c_took + 1;
      else
        c_kept := c_kept + 1;
      end if;
      insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
      values ('auto_resolve', v_rule, 'crm_import_conflicts', ic.id, v_rule, v_run);
      v_n := v_n + 1;
    end loop;

    -- ---------------------------------------------- 2. auto-merge (§4), unless suspended
    if not v_suspended then
      for cand in select * from public.crm_duplicate_candidates(1000) loop
        exit when v_n >= v_lim;
        select * into pa from public.crm_people where id = cand.person_a and user_id = v_uid and not archived;
        select * into pb from public.crm_people where id = cand.person_b and user_id = v_uid and not archived;
        continue when pa.id is null or pb.id is null;   -- merged earlier in this run
        names_ok := (pa.family_name is not null and pb.family_name is not null
                     and lower(btrim(pa.family_name)) = lower(btrim(pb.family_name)))
                    or strpos(pa.name_normalized, pb.name_normalized) > 0
                    or strpos(pb.name_normalized, pa.name_normalized) > 0;
        v_rule := null;
        -- SB-583: a shared phone also needs compatible given names (same surname is not enough).
        by_email := exists (select 1 from unnest(cand.reasons) x where x like 'same email %');
        by_phone := exists (select 1 from unnest(cand.reasons) x where x like 'same phone %')
                    and public.crm_given_names_compatible(
                          public.crm_name_tokens(pa.given_name, pa.preferred_name, pa.display_name),
                          public.crm_name_tokens(pb.given_name, pb.preferred_name, pb.display_name));
        if names_ok and (by_email or by_phone) then
          v_rule := 'auto_merge_contact';
        elsif pa.name_normalized = pb.name_normalized
              and exists (select 1 from public.crm_affiliations a1
                            join public.crm_affiliations a2 on a2.organization_id = a1.organization_id
                                                           and a2.person_id = pb.id and not a2.archived
                           where a1.person_id = pa.id and not a1.archived) then
          v_rule := 'auto_merge_name_org';
        end if;
        continue when v_rule is null;
        -- restricted data is never moved without a person
        continue when exists (select 1 from public.crm_facts f where f.person_id in (pa.id, pb.id)
                                and f.sensitivity in ('sensitive','highly_sensitive') and not f.archived)
                   or exists (select 1 from public.crm_actions x where x.person_id in (pa.id, pb.id)
                                and x.sensitivity in ('sensitive','highly_sensitive') and not x.archived)
                   or exists (select 1 from public.crm_interaction_participants ip
                                join public.crm_interactions i on i.id = ip.interaction_id
                               where ip.person_id in (pa.id, pb.id) and not i.archived
                                 and i.sensitivity in ('sensitive','highly_sensitive'));
        -- keeper: higher tier, then confirmed, then more interactions, then older
        select k.id into v_keep from (
          select p.id,
                 position(public.crm_source_tier(p.source_type, p.source_ref) in 'CBA') as tier_rank,
                 p.is_confirmed,
                 (select count(*) from public.crm_interaction_participants ip where ip.person_id = p.id) as n_int,
                 p.created_at
            from public.crm_people p where p.id in (pa.id, pb.id)) k
         order by k.tier_rank desc, k.is_confirmed desc, k.n_int desc, k.created_at, k.id
         limit 1;
        v_merge := case when v_keep = pa.id then pb.id else pa.id end;
        begin
          v_log := public.crm_merge_people(v_keep, v_merge, v_rule);
        exception when others then
          c_merge_err := c_merge_err + 1;
          continue;
        end;
        insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, merge_log_id, run_id)
        values ('auto_merge', v_rule, 'crm_people', v_merge, v_rule, v_log, v_run);
        c_merged := c_merged + 1;
        v_n := v_n + 1;
      end loop;
    end if;

    -- ---------------------------------------------- 3. gray zone (§4)
    for cand in select * from public.crm_duplicate_candidates(1000) where strength = 'possible' loop
      if exists (select 1 from unnest(cand.reasons) x where x like 'both at %')
         or exists (select 1 from public.crm_group_members g1
                      join public.crm_group_members g2 on g2.group_id = g1.group_id and g2.person_id = cand.person_b and not g2.archived
                     where g1.person_id = cand.person_a and not g1.archived)
         or exists (select 1 from public.crm_person_relationships x
                     where not x.archived
                       and ((x.person_id = cand.person_a and x.related_person_id = cand.person_b)
                         or (x.person_id = cand.person_b and x.related_person_id = cand.person_a))) then
        c_gray_left := c_gray_left + 1;   -- shares context: for Jason's digest
        continue;
      end if;
      continue when exists (select 1 from public.crm_people p
                             where p.id in (cand.person_a, cand.person_b) and p.created_at > now() - interval '30 days');
      exit when v_n >= v_lim;
      begin
        v_dis := public.crm_dismiss_duplicate(cand.person_a, cand.person_b, 'auto_dismiss_gray_zone');
      exception when others then
        continue;
      end;
      insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
      values ('auto_dismiss', 'gray_zone_30d', 'crm_duplicate_dismissals', v_dis, 'auto_dismiss_gray_zone', v_run);
      c_dismissed := c_dismissed + 1;
      v_n := v_n + 1;
    end loop;

    -- ---------------------------------------------- 4. confirm (§3)
    for r in select p.id from public.crm_people p
              where p.user_id = v_uid and not p.archived and p.confirmed_at is null and p.source_type <> 'manual'
                and public.crm_source_tier(p.source_type, p.source_ref) = 'A'
              order by p.created_at, p.id loop
      exit when v_n >= v_lim;
      v_k := public.crm_policy_confirm_person(r.id, 'tier_a');
      c_conf_a := c_conf_a + v_k;
      v_n := v_n + v_k;
    end loop;

    v_dups := array(select person_a from public.crm_duplicate_candidates(1000)
                    union select person_b from public.crm_duplicate_candidates(1000));
    for r in select p.id from public.crm_people p
              where p.user_id = v_uid and not p.archived and p.confirmed_at is null
                and public.crm_source_tier(p.source_type, p.source_ref) = 'B'
                and p.captured_at <= now() - interval '14 days'
                and not (p.id = any(v_dups))
              order by p.created_at, p.id loop
      exit when v_n >= v_lim;
      begin
        v_k := public.crm_policy_confirm_person(r.id, 'tier_b_14d');
      exception when sqlstate '22023' then
        continue;   -- not eligible after all (open conflict or shared contact)
      end;
      c_conf_b := c_conf_b + v_k;
      v_n := v_n + v_k;
    end loop;

    for r in select f.id from public.crm_facts f
              where f.user_id = v_uid and not f.archived and f.confirmed_at is null
                and f.sensitivity in ('normal','private')
                and public.crm_source_tier(f.source_type, f.source_ref) = 'C'
                and exists (select 1 from public.crm_facts g
                             where g.user_id = v_uid and g.person_id = f.person_id and g.id <> f.id and not g.archived
                               and g.fact_type = f.fact_type and lower(btrim(g.value)) = lower(btrim(f.value))
                               and coalesce(g.source_ref, '') <> coalesce(f.source_ref, ''))
              order by f.created_at, f.id loop
      exit when v_n >= v_lim;
      update public.crm_facts set confirmed_at = now(), meta = meta || '{"confirmed_by":"policy:tier_c_corroborated"}'
       where id = r.id and user_id = v_uid;
      insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
      values ('auto_confirm', 'tier_c_corroborated', 'crm_facts', r.id, 'auto_confirm_tier_c_corroborated', v_run);
      c_conf_c := c_conf_c + 1;
      v_n := v_n + 1;
    end loop;

    -- ---------------------------------------------- 5. expire Tier C after 60 days (archive only)
    for r in select f.id from public.crm_facts f
              where f.user_id = v_uid and not f.archived and f.confirmed_at is null
                and f.sensitivity in ('normal','private') and f.captured_at <= now() - interval '60 days'
                and public.crm_source_tier(f.source_type, f.source_ref) = 'C'
              order by f.captured_at, f.id loop
      exit when v_n >= v_lim;
      update public.crm_facts set archived = true where id = r.id and user_id = v_uid;
      insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
      values ('auto_expire', 'tier_c_60d', 'crm_facts', r.id, 'auto_expire_tier_c', v_run);
      c_exp_f := c_exp_f + 1;
      v_n := v_n + 1;
    end loop;
    for r in select i.id from public.crm_interactions i
              where i.user_id = v_uid and not i.archived and i.confirmed_at is null
                and i.sensitivity in ('normal','private') and i.captured_at <= now() - interval '60 days'
                and public.crm_source_tier(i.source_type, i.source_ref) = 'C'
              order by i.captured_at, i.id loop
      exit when v_n >= v_lim;
      update public.crm_interactions set archived = true where id = r.id and user_id = v_uid;
      insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
      values ('auto_expire', 'tier_c_60d', 'crm_interactions', r.id, 'auto_expire_tier_c', v_run);
      c_exp_i := c_exp_i + 1;
      v_n := v_n + 1;
    end loop;

    v_summary := jsonb_build_object(
      'run_id', v_run, 'limit', v_lim, 'decisions', v_n, 'capped', v_n >= v_lim,
      'conflicts', jsonb_build_object('took_incoming', c_took, 'kept_existing', c_kept,
                                      'left_tier_a_vs_a', c_left_aa, 'errors', c_res_err),
      'merges', jsonb_build_object('merged', c_merged, 'errors', c_merge_err, 'suspended', v_suspended),
      'gray_zone', jsonb_build_object('dismissed', c_dismissed, 'left_for_jason', c_gray_left),
      'confirmed', jsonb_build_object('tier_a', c_conf_a, 'tier_b_14d', c_conf_b, 'tier_c_corroborated', c_conf_c),
      'expired', jsonb_build_object('facts', c_exp_f, 'interactions', c_exp_i));

    if coalesce(p_dry_run, false) then
      raise exception 'steward dry run: roll back' using errcode = 'X5730';
    end if;
  exception when sqlstate 'X5730' then
    null;   -- dry run: everything above is undone; v_summary keeps what would have happened
  end;

  return v_summary || jsonb_build_object('dry_run', coalesce(p_dry_run, false), 'enabled', v_enabled);
end $fn$;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if not public.crm_given_names_compatible(public.crm_name_tokens('Grandpa David', null, null), public.crm_name_tokens('David', null, null))
     or not public.crm_given_names_compatible(public.crm_name_tokens('Alex', null, null), public.crm_name_tokens('Alexander', null, null))
     or not public.crm_given_names_compatible(public.crm_name_tokens('Abbigail', 'Abby', null), public.crm_name_tokens(null, null, 'Abby Coe'))
     or public.crm_given_names_compatible(public.crm_name_tokens('Caren', null, null), public.crm_name_tokens('Lola', null, null))
     or public.crm_given_names_compatible(public.crm_name_tokens('Michael', null, null), public.crm_name_tokens('Greg', null, null))
     or public.crm_given_names_compatible(public.crm_name_tokens('Dr', null, 'Dr Smith'), public.crm_name_tokens('Dr', null, 'Dr Jones'))
     or public.crm_given_names_compatible(public.crm_name_tokens(null, null, null), public.crm_name_tokens('Al', null, null)) then
    raise exception 'A1: given-name compatibility cases failed';
  end if;
  if exists (select 1 from pg_proc where oid in ('public.crm_import_contacts(jsonb,text)'::regprocedure,
                                                 'public.crm_steward_run(boolean,integer)'::regprocedure,
                                                 'public.crm_name_tokens(text,text,text)'::regprocedure,
                                                 'public.crm_given_names_compatible(text[],text[])'::regprocedure)
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_import_contacts(jsonb,text)', 'execute')
     or has_function_privilege('anon', 'public.crm_steward_run(boolean,integer)', 'execute') then
    raise exception 'A2: functions must be SECURITY INVOKER, pinned, and closed to anon';
  end if;
  if position('crm_given_names_compatible' in (select prosrc from pg_proc where oid = 'public.crm_import_contacts(jsonb,text)'::regprocedure)) = 0
     or position('crm_given_names_compatible' in (select prosrc from pg_proc where oid = 'public.crm_steward_run(boolean,integer)'::regprocedure)) = 0 then
    raise exception 'A3: the phone guard is missing from the import or the steward';
  end if;
end $chk$;
