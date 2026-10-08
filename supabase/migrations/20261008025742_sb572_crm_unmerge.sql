-- SB-572 (ADR-CRM-006 §4.1): a merge can be undone exactly.
--
-- * crm_merge_log.undo: what crm_merge_people moved, archived in place and filled, as ids and
--   flags only (no names or values; the merged person's row still holds its values).
-- * crm_merge_people: unchanged behaviour, now also writes undo.
-- * crm_unmerge(merge_log_id, reason): restores the pre-merge state, or refuses (55000) and
--   changes nothing when anything recorded has changed since the merge.
-- * crm_unmerges: append-only record of each undo. The pair is dismissed as a duplicate so
--   it is not proposed, or merged by the steward, again.

-- ---------------------------------------------------------------- undo record on the merge log
alter table public.crm_merge_log
  add column undo jsonb check (undo is null or jsonb_typeof(undo) = 'object');
comment on column public.crm_merge_log.undo is
  'SB-572 / ADR-CRM-006 §4.1. {moved: {"table.column": [{id, pref_reset}]}, kept: {"table": [{id, was_archived}]}, '
  'filled: [field]}. Ids and flags only. Null for merges made before SB-572.';

-- ---------------------------------------------------------------- crm_merge_people (records undo)
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
      if done then
        n_moved := n_moved + 1;
        u_list := u_list || jsonb_build_array(jsonb_build_object('id', rid, 'pref_reset', reset));
      else
        -- cannot move without breaking a rule: keep it on the merged person, archived
        execute format('update public.%I set archived = true where id = $1', t) using rid;
        n_kept := n_kept + 1;
        k_list := k_list || jsonb_build_array(jsonb_build_object('id', rid, 'was_archived', was_arch));
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

-- ---------------------------------------------------------------- undo record table
-- Like crm_merge_log: no foreign keys, append-only for every role.
create table public.crm_unmerges (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid(),
  actor_id         uuid default auth.uid(),
  merge_log_id     uuid not null,
  kept_person_id   uuid not null,
  merged_person_id uuid not null,
  reason_code      text not null check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  restored         jsonb not null default '{}'::jsonb check (jsonb_typeof(restored) = 'object'),
  created_at       timestamptz not null default now(),
  constraint crm_unmerges_once unique (user_id, merge_log_id)
);
comment on table public.crm_unmerges is
  'SB-572 / ADR-CRM-006 §4.1. One row per undone merge: which merge, who, why, counts restored. Append-only.';
create index crm_unmerges_user_time on public.crm_unmerges (user_id, created_at desc);

create trigger trg_crm_unmerges_append_only
  before update or delete on public.crm_unmerges
  for each row execute function public.crm_append_only();

alter table public.crm_unmerges enable row level security;
revoke all on public.crm_unmerges from public, anon, authenticated;
grant select, insert on public.crm_unmerges to authenticated;
create policy crm_unmerges_select_own on public.crm_unmerges
  for select to authenticated using (user_id = (select auth.uid()));
create policy crm_unmerges_insert_own on public.crm_unmerges
  for insert to authenticated with check (user_id = (select auth.uid()) and actor_id = (select auth.uid()));

-- ---------------------------------------------------------------- crm_unmerge
create function public.crm_unmerge(p_merge_log_id uuid, p_reason text)
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
      if t = 'crm_person_relationships' then
        execute format('select exists (select 1 from public.%I where id = $1 and user_id = $2
                          and $3 in (person_id, related_person_id) and updated_at <= $4)', t)
          into ok using (x->>'id')::uuid, v_uid, k.id, lg.created_at;
      else
        execute format('select exists (select 1 from public.%I where id = $1 and user_id = $2
                          and %I = $3 and updated_at <= $4)', t, col)
          into ok using (x->>'id')::uuid, v_uid, k.id, lg.created_at;
      end if;
      if not ok then
        raise exception 'a moved row has changed since the merge' using errcode = '55000';
      end if;
    end loop;
  end loop;
  for e in select key, value from jsonb_each(coalesce(lg.undo->'kept', '{}'::jsonb)) loop
    if not (e.key = any(array(select split_part(a, '.', 1) from unnest(allowed) a))) then
      raise exception 'undo record names an unknown table' using errcode = '55000';
    end if;
    for x in select value from jsonb_array_elements(e.value) loop
      execute format('select exists (select 1 from public.%I where id = $1 and user_id = $2
                        and archived and updated_at <= $3)', e.key)
        into ok using (x->>'id')::uuid, v_uid, lg.created_at;
      if not ok then
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
comment on function public.crm_unmerge(uuid, text) is
  'SB-572 / ADR-CRM-006 §4.1. Undo one merge exactly from crm_merge_log.undo, or refuse (55000) with no change.';
revoke all on function public.crm_unmerge(uuid, text) from public, anon;
grant execute on function public.crm_unmerge(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  -- A1: both functions SECURITY INVOKER, search_path pinned, not callable by anon.
  if exists (select 1 from pg_proc where oid in ('public.crm_merge_people(uuid,uuid,text)'::regprocedure,
                                               'public.crm_unmerge(uuid,text)'::regprocedure)
              and (prosecdef or not proconfig @> array['search_path=""'])) then
    raise exception 'A1: merge/unmerge must be SECURITY INVOKER with a pinned search_path';
  end if;
  if has_function_privilege('anon', 'public.crm_merge_people(uuid,uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.crm_unmerge(uuid,text)', 'execute') then
    raise exception 'A1: anon can execute merge or unmerge';
  end if;
  -- A2: crm_unmerges is RLS-protected, append-only, select/insert only.
  if not (select relrowsecurity from pg_class where oid = 'public.crm_unmerges'::regclass)
     or not exists (select 1 from pg_trigger where tgname = 'trg_crm_unmerges_append_only')
     or has_table_privilege('authenticated', 'public.crm_unmerges', 'update')
     or has_table_privilege('authenticated', 'public.crm_unmerges', 'delete')
     or has_table_privilege('anon', 'public.crm_unmerges', 'select') then
    raise exception 'A2: crm_unmerges protections are wrong';
  end if;
  -- A3: only merge and unmerge ever set merged_into_id.
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname = 'public' and p.proname not in ('crm_merge_people', 'crm_unmerge')
                and p.prosrc ~* 'merged_into_id\s*=') then
    raise exception 'A3: another function sets merged_into_id';
  end if;
  -- A4: the merge function writes the undo record.
  if (select prosrc from pg_proc where oid = 'public.crm_merge_people(uuid,uuid,text)'::regprocedure) !~ 'undo' then
    raise exception 'A4: crm_merge_people does not record undo';
  end if;
end $chk$;
