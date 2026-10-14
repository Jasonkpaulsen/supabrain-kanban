-- SB-573 (ADR-CRM-006 §4.2): the CRM steward run.
--
-- crm_steward_run(p_dry_run, p_limit) applies the written policy as the owner, in order:
-- resolve import conflicts, auto-merge, dismiss gray-zone pairs, confirm, expire. Every
-- automatic decision is a crm_steward_decisions row carrying the run id. A real run needs the
-- owner's active "CRM Data Steward" agent with automation enabled (kill switch); a dry run is
-- always allowed and is rolled back. Restricted rows are never touched.
-- crm_policy_confirm_person keeps its one signature and now also takes 'tier_b_14d'.

-- ---------------------------------------------------------------- policy confirmation (+ tier_b_14d, run id)
create or replace function public.crm_policy_confirm_person(p_person_id uuid, p_policy text)
returns integer
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  v_person public.crm_people%rowtype;
  v_ref    text;
  v_tag    jsonb;
  v_reason text;
  v_run    uuid := nullif(current_setting('crm.steward_run_id', true), '')::uuid;
  v_before timestamptz;
  v_n      int := 0;
  t        text;
  v_rid    uuid;
begin
  if v_uid is null then
    raise exception 'policy confirmation needs a signed-in owner' using errcode = '42501';
  end if;
  if p_policy is null or p_policy not in ('tier_a', 'tier_b_14d') then
    raise exception 'unknown confirmation policy %', coalesce(p_policy, '(null)') using errcode = '22023';
  end if;
  select * into v_person from public.crm_people p
   where p.id = p_person_id and p.user_id = v_uid and not p.archived;
  if v_person.id is null then
    raise exception 'no such live person for this owner' using errcode = '42501';
  end if;

  if p_policy = 'tier_a' then
    if public.crm_source_tier(v_person.source_type, v_person.source_ref) <> 'A' then
      raise exception 'policy tier_a applies only to Tier A people' using errcode = '22023';
    end if;
    if v_person.source_type = 'manual' then
      return 0;  -- manual rows are confirmed by definition
    end if;
    v_before := 'infinity';
  else
    -- tier_b_14d: structured system data, 14 quiet days, nothing contradicting it
    if public.crm_source_tier(v_person.source_type, v_person.source_ref) <> 'B' then
      raise exception 'policy tier_b_14d applies only to Tier B people' using errcode = '22023';
    end if;
    if v_person.captured_at > now() - interval '14 days'
       or exists (select 1 from public.crm_import_conflicts c
                   where c.user_id = v_uid and c.person_id = v_person.id and c.status = 'open' and not c.archived)
       or exists (select 1 from public.crm_contact_points a
                    join public.crm_contact_points b on b.user_id = a.user_id and b.kind = a.kind
                                                    and b.value_normalized = a.value_normalized and b.person_id <> a.person_id
                                                    and not b.archived
                    join public.crm_people o on o.id = b.person_id and not o.archived
                   where a.user_id = v_uid and a.person_id = v_person.id and a.kind in ('email', 'phone') and not a.archived) then
      raise exception 'person is not eligible for tier_b_14d' using errcode = '22023';
    end if;
    v_before := now() - interval '14 days';
  end if;

  v_ref := v_person.source_ref;
  v_tag := jsonb_build_object('confirmed_by', 'policy:' || p_policy);
  v_reason := 'auto_confirm_' || p_policy;

  -- The person and every unconfirmed live row it carries from the same source.
  -- Never a row the owner edited after capture, never a restricted fact (ADR-CRM-006 §3).
  for t, v_rid in
    select 'crm_people', x.id from public.crm_people x
     where x.id = v_person.id and x.user_id = v_uid and x.confirmed_at is null
    union all
    select 'crm_contact_points', x.id from public.crm_contact_points x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref and x.captured_at <= v_before
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_affiliations', x.id from public.crm_affiliations x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref and x.captured_at <= v_before
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_important_dates', x.id from public.crm_important_dates x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref and x.captured_at <= v_before
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_person_relationships', x.id from public.crm_person_relationships x
     where (x.person_id = v_person.id or x.related_person_id = v_person.id) and x.user_id = v_uid
       and x.source_ref = v_ref and x.captured_at <= v_before and x.confirmed_at is null and not x.archived
       and x.updated_at <= x.captured_at + interval '1 minute'
    union all
    select 'crm_facts', x.id from public.crm_facts x
     where x.person_id = v_person.id and x.user_id = v_uid and x.source_ref = v_ref and x.captured_at <= v_before
       and x.sensitivity in ('normal','private')
       and x.confirmed_at is null and not x.archived and x.updated_at <= x.captured_at + interval '1 minute'
  loop
    execute format('update public.%I set confirmed_at = now(), meta = meta || $1 where id = $2 and user_id = $3', t)
      using v_tag, v_rid, v_uid;
    insert into public.crm_steward_decisions (decision, rule, entity_type, entity_id, reason_code, run_id)
    values ('auto_confirm', p_policy, t, v_rid, v_reason, v_run);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $fn$;

-- ---------------------------------------------------------------- the steward run
create function public.crm_steward_run(p_dry_run boolean default false, p_limit integer default 200)
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
        if names_ok and exists (select 1 from unnest(cand.reasons) x where x like 'same email %' or x like 'same phone %') then
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
comment on function public.crm_steward_run(boolean, integer) is
  'SB-573 / ADR-CRM-006 §4.2. Apply the steward policy as the owner: conflicts, merges, gray zone, confirm, expire. '
  'Bounded, logged per decision, kill-switched by the CRM Data Steward agent; dry run is rolled back.';
revoke all on function public.crm_steward_run(boolean, integer) from public, anon;
grant execute on function public.crm_steward_run(boolean, integer) to authenticated, service_role;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if (select count(*) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'public' and p.proname = 'crm_policy_confirm_person') <> 1 then
    raise exception 'A1: crm_policy_confirm_person must keep exactly one signature';
  end if;
  if exists (select 1 from pg_proc where oid in ('public.crm_steward_run(boolean,integer)'::regprocedure,
                                               'public.crm_policy_confirm_person(uuid,text)'::regprocedure)
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_steward_run(boolean,integer)', 'execute') then
    raise exception 'A2: steward functions must be SECURITY INVOKER, pinned, and closed to anon';
  end if;
  if exists (select 1 from cron.job where command ~* 'crm_steward_run') then
    raise exception 'A3: the steward run must not be scheduled as postgres';
  end if;
  -- only merge and unmerge set merged_into_id (the run merges through crm_merge_people)
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname = 'public' and p.proname not in ('crm_merge_people', 'crm_unmerge')
                and p.prosrc ~* 'merged_into_id\s*=') then
    raise exception 'A4: another function sets merged_into_id';
  end if;
end $chk$;
