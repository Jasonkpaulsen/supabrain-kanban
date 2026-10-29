-- SB-572 follow-up (ADR-CRM-006 §4.1): detect "changed since the merge" by row fingerprint.
--
-- The first version compared updated_at with the merge time. now() is fixed for a whole
-- transaction, so an edit made in the same transaction as the merge would not be seen. Each
-- moved or kept row now carries fp = md5 of the row (without updated_at) as the merge left it,
-- and crm_unmerge refuses unless every fingerprint still matches. A fingerprint is a hash, not
-- readable content. No merge has been made since SB-572, so no undo record lacks fp.

create or replace function public.crm_merge_people(p_keep_id uuid, p_merge_id uuid, p_reason text)
returns uuid
language plpgsql security invoker set search_path = '' as $fn$
declare
  v_uid   uuid := auth.uid();
  k       public.crm_people%rowtype;
  m       public.crm_people%rowtype;
  -- every column that points at a person; allowlisted, never caller-supplied
  targets text[] := array[
    'crm_contact_points.person_id', 'crm_addresses.person_id',
    'crm_person_relationships.person_id', 'crm_person_relationships.related_person_id',
    'crm_affiliations.person_id', 'crm_group_members.person_id', 'crm_entity_tags.person_id',
    'crm_important_dates.person_id', 'crm_facts.person_id',
    'crm_interaction_participants.person_id', 'crm_actions.person_id'];
  fields  text[] := array['given_name', 'middle_name', 'family_name', 'preferred_name', 'pronouns',
                          'contact_cadence_days', 'relationship_priority'];
  tgt     text;
  t       text;
  col     text;
  f       text;
  rid     uuid;
  done    boolean;
  reset   boolean;
  was_arch boolean;
  fp      text;
  n_moved int;
  n_kept  int;
  total   int := 0;
  moved   jsonb := '{}'::jsonb;
  kept    jsonb := '{}'::jsonb;
  u_moved jsonb := '{}'::jsonb;
  u_kept  jsonb := '{}'::jsonb;
  u_list  jsonb;
  k_list  jsonb;
  filled  jsonb := '[]'::jsonb;
  v_log   uuid;
begin
  if v_uid is null then
    raise exception 'merge needs a signed-in user' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'merge needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;
  if p_keep_id is null or p_merge_id is null or p_keep_id = p_merge_id then
    raise exception 'merge needs two different people' using errcode = '22023';
  end if;
  select * into k from public.crm_people where id = p_keep_id and user_id = v_uid and not archived for update;
  if not found then
    raise exception 'person to keep not found' using errcode = 'P0002';
  end if;
  select * into m from public.crm_people where id = p_merge_id and user_id = v_uid and not archived for update;
  if not found then
    raise exception 'person to merge not found' using errcode = 'P0002';
  end if;

  foreach tgt in array targets loop
    t := split_part(tgt, '.', 1);
    col := split_part(tgt, '.', 2);
    n_moved := 0;
    n_kept := 0;
    u_list := '[]'::jsonb;
    k_list := '[]'::jsonb;
    for rid in execute format('select id from public.%I where %I = $1', t, col) using p_merge_id loop
      execute format('select archived from public.%I where id = $1', t) into was_arch using rid;
      done := false;
      reset := false;
      begin
        execute format('update public.%I set %I = $1 where id = $2', t, col) using p_keep_id, rid;
        done := true;
      exception when unique_violation or check_violation then
        null;
      end;
      if not done and t in ('crm_contact_points', 'crm_addresses') then
        -- a clash on "one preferred per person": move it as not-preferred
        begin
          execute format('update public.%I set %I = $1, is_preferred = false where id = $2', t, col) using p_keep_id, rid;
          done := true;
          reset := true;
        exception when unique_violation or check_violation then
          null;
        end;
      end if;
      if not done then
        -- cannot move without breaking a rule: keep it on the merged person, archived
        execute format('update public.%I set archived = true where id = $1', t) using rid;
      end if;
      -- fingerprint of the row as the merge left it: undo refuses if it changes afterwards
      execute format('select md5((to_jsonb(x) - ''updated_at'')::text) from public.%I x where id = $1', t)
        into fp using rid;
      if done then
        n_moved := n_moved + 1;
        u_list := u_list || jsonb_build_array(jsonb_build_object('id', rid, 'pref_reset', reset, 'fp', fp));
      else
        n_kept := n_kept + 1;
        k_list := k_list || jsonb_build_array(jsonb_build_object('id', rid, 'was_archived', was_arch, 'fp', fp));
      end if;
    end loop;
    if n_moved > 0 then
      moved := moved || jsonb_build_object(tgt, n_moved);
      u_moved := u_moved || jsonb_build_object(tgt, u_list);
    end if;
    if n_kept > 0 then
      kept := kept || jsonb_build_object(tgt, n_kept);
      u_kept := u_kept || jsonb_build_object(t, coalesce(u_kept->t, '[]'::jsonb) || k_list);
    end if;
    total := total + n_moved;
  end loop;

  -- which blanks on the kept person the merged person fills (names only, for undo)
  foreach f in array fields loop
    if to_jsonb(k)->f = 'null'::jsonb and to_jsonb(m)->f <> 'null'::jsonb then
      filled := filled || to_jsonb(f);
    end if;
  end loop;

  -- fill blanks on the kept person; never overwrite
  update public.crm_people
     set given_name            = coalesce(given_name, m.given_name),
         middle_name           = coalesce(middle_name, m.middle_name),
         family_name           = coalesce(family_name, m.family_name),
         preferred_name        = coalesce(preferred_name, m.preferred_name),
         pronouns              = coalesce(pronouns, m.pronouns),
         contact_cadence_days  = coalesce(contact_cadence_days, m.contact_cadence_days),
         relationship_priority = coalesce(relationship_priority, m.relationship_priority)
   where id = p_keep_id;

  -- retire the merged person; it stays as the traceable source record
  update public.crm_people
     set archived = true, merged_into_id = p_keep_id, merged_at = now()
   where id = p_merge_id;

  insert into public.crm_merge_log
    (user_id, actor_id, kept_person_id, merged_person_id, merged_display_name, reason_code, moved, kept_on_merged, undo)
  values (v_uid, v_uid, p_keep_id, p_merge_id, m.display_name, p_reason, moved, kept,
          jsonb_build_object('moved', u_moved, 'kept', u_kept, 'filled', filled))
  returning id into v_log;

  perform public.crm_audit('merge', 'crm_people', p_keep_id, total, 'succeeded', p_reason);
  return v_log;
end $fn$;

create or replace function public.crm_unmerge(p_merge_log_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid    uuid := auth.uid();
  lg       public.crm_merge_log%rowtype;
  k        public.crm_people%rowtype;
  m        public.crm_people%rowtype;
  fields   text[] := array['given_name', 'middle_name', 'family_name', 'preferred_name', 'pronouns',
                           'contact_cadence_days', 'relationship_priority'];
  allowed  text[] := array[
    'crm_contact_points.person_id', 'crm_addresses.person_id',
    'crm_person_relationships.person_id', 'crm_person_relationships.related_person_id',
    'crm_affiliations.person_id', 'crm_group_members.person_id', 'crm_entity_tags.person_id',
    'crm_important_dates.person_id', 'crm_facts.person_id',
    'crm_interaction_participants.person_id', 'crm_actions.person_id'];
  e        record;
  x        jsonb;
  t        text;
  col      text;
  f        text;
  ok       boolean;
  n_back   int := 0;
  n_unarch int := 0;
  n_clear  int := 0;
begin
  if v_uid is null then
    raise exception 'unmerge needs a signed-in user' using errcode = '42501';
  end if;
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'unmerge needs a reason code (snake_case, 3-64 chars)' using errcode = '22023';
  end if;
  select * into lg from public.crm_merge_log l where l.id = p_merge_log_id and l.user_id = v_uid;
  if not found then
    raise exception 'merge not found' using errcode = 'P0002';
  end if;
  if lg.undo is null then
    raise exception 'this merge predates undo recording and cannot be undone' using errcode = '55000';
  end if;
  if exists (select 1 from public.crm_unmerges u where u.user_id = v_uid and u.merge_log_id = lg.id) then
    raise exception 'this merge has already been undone' using errcode = '55000';
  end if;
  select * into k from public.crm_people p where p.id = lg.kept_person_id and p.user_id = v_uid for update;
  select * into m from public.crm_people p where p.id = lg.merged_person_id and p.user_id = v_uid for update;
  if k.id is null or k.archived or k.merged_into_id is not null then
    raise exception 'the kept person has been archived or merged since' using errcode = '55000';
  end if;
  if m.id is null or not m.archived or m.merged_into_id is distinct from k.id then
    raise exception 'the merged person is no longer merged into the kept person' using errcode = '55000';
  end if;

  -- ---------------------------------------------- verify everything first; change nothing yet
  for e in select key, value from jsonb_each(coalesce(lg.undo->'moved', '{}'::jsonb)) loop
    if not (e.key = any(allowed)) then
      raise exception 'undo record names an unknown column' using errcode = '55000';
    end if;
    t := split_part(e.key, '.', 1);
    col := split_part(e.key, '.', 2);
    for x in select value from jsonb_array_elements(e.value) loop
      execute format('select exists (select 1 from public.%I x where x.id = $1 and x.user_id = $2
                        and md5((to_jsonb(x) - ''updated_at'')::text) = $3)', t)
        into ok using (x->>'id')::uuid, v_uid, x->>'fp';
      if not coalesce(ok, false) then
        raise exception 'a moved row has changed since the merge' using errcode = '55000';
      end if;
    end loop;
  end loop;
  for e in select key, value from jsonb_each(coalesce(lg.undo->'kept', '{}'::jsonb)) loop
    if not (e.key = any(array(select split_part(a, '.', 1) from unnest(allowed) a))) then
      raise exception 'undo record names an unknown table' using errcode = '55000';
    end if;
    for x in select value from jsonb_array_elements(e.value) loop
      execute format('select exists (select 1 from public.%I x where x.id = $1 and x.user_id = $2
                        and md5((to_jsonb(x) - ''updated_at'')::text) = $3)', e.key)
        into ok using (x->>'id')::uuid, v_uid, x->>'fp';
      if not coalesce(ok, false) then
        raise exception 'a row archived by the merge has changed since' using errcode = '55000';
      end if;
    end loop;
  end loop;
  for f in select jsonb_array_elements_text(coalesce(lg.undo->'filled', '[]'::jsonb)) loop
    if not (f = any(fields)) then
      raise exception 'undo record names an unknown field' using errcode = '55000';
    end if;
    if (to_jsonb(k)->f) is distinct from (to_jsonb(m)->f) then
      raise exception 'a field filled by the merge has been edited since' using errcode = '55000';
    end if;
  end loop;

  -- ---------------------------------------------- restore
  for e in select key, value from jsonb_each(coalesce(lg.undo->'moved', '{}'::jsonb)) loop
    t := split_part(e.key, '.', 1);
    col := split_part(e.key, '.', 2);
    for x in select value from jsonb_array_elements(e.value) loop
      if t = 'crm_person_relationships' then
        -- either side may hold the kept person (symmetric types are re-ordered by the guard)
        update public.crm_person_relationships
           set person_id = case when person_id = k.id then m.id else person_id end,
               related_person_id = case when related_person_id = k.id then m.id else related_person_id end
         where id = (x->>'id')::uuid and user_id = v_uid;
      elsif (x->>'pref_reset')::boolean then
        execute format('update public.%I set %I = $1, is_preferred = true where id = $2 and user_id = $3', t, col)
          using m.id, (x->>'id')::uuid, v_uid;
      else
        execute format('update public.%I set %I = $1 where id = $2 and user_id = $3', t, col)
          using m.id, (x->>'id')::uuid, v_uid;
      end if;
      n_back := n_back + 1;
    end loop;
  end loop;
  for e in select key, value from jsonb_each(coalesce(lg.undo->'kept', '{}'::jsonb)) loop
    for x in select value from jsonb_array_elements(e.value) loop
      if not (x->>'was_archived')::boolean then
        execute format('update public.%I set archived = false where id = $1 and user_id = $2', e.key)
          using (x->>'id')::uuid, v_uid;
        n_unarch := n_unarch + 1;
      end if;
    end loop;
  end loop;
  for f in select jsonb_array_elements_text(coalesce(lg.undo->'filled', '[]'::jsonb)) loop
    execute format('update public.crm_people set %I = null where id = $1 and user_id = $2', f) using k.id, v_uid;
    n_clear := n_clear + 1;
  end loop;

  update public.crm_people
     set archived = false, merged_into_id = null, merged_at = null
   where id = m.id and user_id = v_uid;

  insert into public.crm_unmerges (merge_log_id, kept_person_id, merged_person_id, reason_code, restored)
  values (lg.id, k.id, m.id, p_reason,
          jsonb_build_object('rows_moved_back', n_back, 'rows_unarchived', n_unarch, 'fields_cleared', n_clear));

  -- never propose this pair again
  insert into public.crm_duplicate_dismissals (person_a, person_b, reason_code)
  select least(k.id, m.id), greatest(k.id, m.id), 'unmerged'
   where not exists (select 1 from public.crm_duplicate_dismissals d
                      where d.user_id = v_uid and not d.archived
                        and d.person_a = least(k.id, m.id) and d.person_b = greatest(k.id, m.id));

  return jsonb_build_object('merge_log_id', lg.id, 'kept_person_id', k.id, 'restored_person_id', m.id,
                            'rows_moved_back', n_back, 'rows_unarchived', n_unarch, 'fields_cleared', n_clear);
end $fn$;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if (select prosrc from pg_proc where oid = 'public.crm_merge_people(uuid,uuid,text)'::regprocedure) !~ '''fp'''
     or (select prosrc from pg_proc where oid = 'public.crm_unmerge(uuid,text)'::regprocedure) !~ '''fp''' then
    raise exception 'A1: merge and unmerge must use row fingerprints';
  end if;
  if (select prosrc from pg_proc where oid = 'public.crm_unmerge(uuid,text)'::regprocedure) ~ 'updated_at <=' then
    raise exception 'A2: crm_unmerge still compares timestamps';
  end if;
  if exists (select 1 from pg_proc where oid in ('public.crm_merge_people(uuid,uuid,text)'::regprocedure,
                                               'public.crm_unmerge(uuid,text)'::regprocedure)
              and (prosecdef or not proconfig @> array['search_path=""']))
     or has_function_privilege('anon', 'public.crm_unmerge(uuid,text)', 'execute') then
    raise exception 'A3: merge/unmerge posture changed';
  end if;
  if exists (select 1 from public.crm_merge_log where undo is not null) then
    raise exception 'A4: undo records without fingerprints exist';
  end if;
end $chk$;
