-- SB-467: explicit, reviewed person merge with a merge log. ADR-CRM-003 §5.
--
-- crm_merge_people(keep, merge, reason) is the only way two people become one.
-- It is SECURITY INVOKER and checks auth.uid() itself, so it can only see and
-- move the caller's own rows. It:
--   1. moves every reference to the merged person onto the kept one, archived
--      history included, leaving each row's provenance untouched;
--   2. keeps a row that cannot move (a duplicate email, group membership or
--      participation; a relationship between the two, which would become a
--      self-link) on the merged person, archived, as history. A preferred
--      contact point or address that would clash moves as not-preferred;
--   3. fills the kept person's blanks from the merged one, never overwriting;
--   4. archives the merged person with merged_into_id and merged_at;
--   5. writes crm_merge_log (append-only) and a 'merge' audit row.

-- ---------------------------------------------------------------- merged person
alter table public.crm_people
  add column merged_into_id uuid,
  add column merged_at      timestamptz,
  add constraint crm_people_not_merged_into_self check (merged_into_id is distinct from id),
  add constraint crm_people_merged_is_archived  check (merged_into_id is null or archived),
  -- only the pointer is cleared if the kept person is ever removed
  add constraint crm_people_merged_into_fk foreign key (merged_into_id, user_id)
    references public.crm_people (id, user_id) on delete set null (merged_into_id);

create index crm_people_merged_into on public.crm_people (merged_into_id, user_id) where merged_into_id is not null;

-- ---------------------------------------------------------------- merge log
-- Like crm_audit_log: no FKs, so it outlives anything it names and can never
-- block a cascade, and append-only for every role.
create table public.crm_merge_log (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null,
  actor_id            uuid default auth.uid(),
  kept_person_id      uuid not null,
  merged_person_id    uuid not null,
  merged_display_name text not null,
  reason_code         text not null check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  moved               jsonb not null default '{}'::jsonb,
  kept_on_merged      jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);
comment on table public.crm_merge_log is
  'SB-467 / ADR-CRM-003. One row per merge: who into whom, why, and per-table counts of rows moved '
  'and of rows kept (archived) on the merged person. Append-only.';

create index crm_merge_log_user_time on public.crm_merge_log (user_id, created_at desc);
create index crm_merge_log_kept   on public.crm_merge_log (kept_person_id);
create index crm_merge_log_merged on public.crm_merge_log (merged_person_id);

create function public.crm_append_only()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  raise exception '% is append-only (% refused)', tg_table_name, tg_op using errcode = '42501';
end $fn$;
revoke all on function public.crm_append_only() from public, anon, authenticated;

create trigger trg_crm_merge_log_append_only
  before update or delete on public.crm_merge_log
  for each row execute function public.crm_append_only();

alter table public.crm_merge_log enable row level security;
revoke all on public.crm_merge_log from public, anon, authenticated;
grant select, insert on public.crm_merge_log to authenticated;
create policy crm_merge_log_select_own on public.crm_merge_log
  for select to authenticated using (user_id = (select auth.uid()));
create policy crm_merge_log_insert_own on public.crm_merge_log
  for insert to authenticated with check (user_id = (select auth.uid()) and actor_id = (select auth.uid()));

-- ---------------------------------------------------------------- crm_merge_people
create function public.crm_merge_people(p_keep_id uuid, p_merge_id uuid, p_reason text)
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
  tgt     text;
  t       text;
  col     text;
  rid     uuid;
  done    boolean;
  n_moved int;
  n_kept  int;
  total   int := 0;
  moved   jsonb := '{}'::jsonb;
  kept    jsonb := '{}'::jsonb;
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
    for rid in execute format('select id from public.%I where %I = $1', t, col) using p_merge_id loop
      done := false;
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
        exception when unique_violation or check_violation then
          null;
        end;
      end if;
      if done then
        n_moved := n_moved + 1;
      else
        -- cannot move without breaking a rule: keep it on the merged person, archived
        execute format('update public.%I set archived = true where id = $1', t) using rid;
        n_kept := n_kept + 1;
      end if;
    end loop;
    if n_moved > 0 then moved := moved || jsonb_build_object(tgt, n_moved); end if;
    if n_kept  > 0 then kept  := kept  || jsonb_build_object(tgt, n_kept);  end if;
    total := total + n_moved;
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
    (user_id, actor_id, kept_person_id, merged_person_id, merged_display_name, reason_code, moved, kept_on_merged)
  values (v_uid, v_uid, p_keep_id, p_merge_id, m.display_name, p_reason, moved, kept)
  returning id into v_log;

  perform public.crm_audit('merge', 'crm_people', p_keep_id, total, 'succeeded', p_reason);
  return v_log;
end $fn$;

revoke all on function public.crm_merge_people(uuid, uuid, text) from public, anon;
grant execute on function public.crm_merge_people(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_people');
  if (select prosecdef from pg_proc where oid = 'public.crm_merge_people(uuid,uuid,text)'::regprocedure) then
    raise exception 'A1: crm_merge_people must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_merge_people(uuid,uuid,text)', 'execute') then
    raise exception 'A2: anon can call crm_merge_people';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.crm_merge_log'::regclass) then
    raise exception 'A3: RLS off on crm_merge_log';
  end if;
  if has_table_privilege('authenticated', 'public.crm_merge_log', 'update')
     or has_table_privilege('authenticated', 'public.crm_merge_log', 'delete')
     or has_table_privilege('authenticated', 'public.crm_merge_log', 'truncate')
     or has_table_privilege('anon', 'public.crm_merge_log', 'select') then
    raise exception 'A4: crm_merge_log privileges are wider than select/insert for authenticated';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_crm_merge_log_append_only') then
    raise exception 'A5: crm_merge_log is not append-only';
  end if;
  -- no automatic merge path: nothing but crm_merge_people sets merged_into_id
  if exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
              where s.nspname = 'public' and p.proname <> 'crm_merge_people'
                and p.prosrc ~* 'merged_into_id\s*=') then
    raise exception 'A6: another function sets merged_into_id';
  end if;
end $chk$;;
