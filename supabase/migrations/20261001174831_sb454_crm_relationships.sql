-- SB-454 (+ SB-463, SB-465): relationship types, person-to-person relationships,
-- and a view that reads every relationship from both ends. ADR-CRM-001 §3.
--
-- A row reads: "person_id is the <label> of related_person_id".
--   parent(A, B) = "A is the parent of B". From B's side, A is 'parent';
--   from A's side, B is the type's inverse_label, 'child'.
-- Symmetric types (sibling, friend, ...) are stored ONCE, in canonical order
-- person_id < related_person_id, so a pair never needs two rows or two person
-- records. The guard trigger swaps a reversed insert into that order, and the
-- unique index then rejects the duplicate.

-- ---------------------------------------------------------------- types
create table public.crm_relationship_types (
  id            uuid primary key default gen_random_uuid(),
  -- null = global type seeded here, readable by every signed-in user and
  -- changeable by none. Set = a user's own custom type.
  user_id       uuid default auth.uid() references auth.users(id) on delete cascade,
  code          text not null check (code ~ '^[a-z][a-z0-9_]{1,40}$'),
  label         text not null check (btrim(label) <> '' and char_length(label) <= 60),
  inverse_label text check (char_length(inverse_label) <= 60),
  is_symmetric  boolean not null default false,
  category      text not null default 'other' check (category in ('family','social','professional','other')),
  archived      boolean not null default false,
  archived_at   timestamptz,
  meta          jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint crm_relationship_types_direction check (
    (is_symmetric and inverse_label is null) or (not is_symmetric and inverse_label is not null))
);
create unique index crm_relationship_types_code
  on public.crm_relationship_types (user_id, code) nulls not distinct;

insert into public.crm_relationship_types (user_id, code, label, inverse_label, is_symmetric, category) values
  (null, 'spouse',       'spouse',       null,            true,  'family'),
  (null, 'partner',      'partner',      null,            true,  'family'),
  (null, 'sibling',      'sibling',      null,            true,  'family'),
  (null, 'cousin',       'cousin',       null,            true,  'family'),
  (null, 'in_law',       'in-law',       null,            true,  'family'),
  (null, 'parent',       'parent',       'child',         false, 'family'),
  (null, 'grandparent',  'grandparent',  'grandchild',    false, 'family'),
  (null, 'guardian',     'guardian',     'ward',          false, 'family'),
  (null, 'aunt_uncle',   'aunt/uncle',   'niece/nephew',  false, 'family'),
  (null, 'friend',       'friend',       null,            true,  'social'),
  (null, 'neighbor',     'neighbor',     null,            true,  'social'),
  (null, 'acquaintance', 'acquaintance', null,            true,  'social'),
  (null, 'colleague',    'colleague',    null,            true,  'professional'),
  (null, 'manager',      'manager',      'direct report', false, 'professional'),
  (null, 'mentor',       'mentor',       'mentee',        false, 'professional'),
  (null, 'teacher',      'teacher',      'student',       false, 'professional'),
  (null, 'provider',     'service provider', 'client',    false, 'professional');

-- Types get the standard triggers, but their policies differ from the owner
-- standard, because global rows must be readable and immutable.
create trigger trg_crm_relationship_types_10_archive before insert or update on public.crm_relationship_types
  for each row execute function public.crm_stamp_archive();
create trigger trg_crm_relationship_types_20_updated_at before update on public.crm_relationship_types
  for each row execute function public.update_updated_at();

alter table public.crm_relationship_types enable row level security;
revoke all on public.crm_relationship_types from public, anon, authenticated;
grant select, insert, update, delete on public.crm_relationship_types to authenticated;

create policy crm_relationship_types_select_global_or_own on public.crm_relationship_types
  for select to authenticated using (user_id is null or user_id = (select auth.uid()));
create policy crm_relationship_types_insert_own on public.crm_relationship_types
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy crm_relationship_types_update_own on public.crm_relationship_types
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy crm_relationship_types_delete_own on public.crm_relationship_types
  for delete to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------- relationships
create table public.crm_person_relationships (
  id                   uuid primary key default gen_random_uuid(),
  user_id              uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id            uuid not null,
  related_person_id    uuid not null,
  relationship_type_id uuid not null references public.crm_relationship_types(id) on delete restrict,
  valid_from           date,
  valid_until          date,
  context              text check (char_length(context) <= 500),
  closeness            smallint check (closeness between 1 and 5),
  priority             smallint check (priority between 1 and 5),
  source_type          text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref           text check (char_length(source_ref) <= 500),
  captured_at          timestamptz not null default now(),
  confidence           numeric(3,2) check (confidence between 0 and 1),
  confirmed_at         timestamptz,
  is_confirmed         boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  archived             boolean not null default false,
  archived_at          timestamptz,
  meta                 jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint crm_person_relationships_not_self check (person_id <> related_person_id),
  constraint crm_person_relationships_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_person_relationships_validity check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint crm_person_relationships_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_person_relationships_related_fk foreign key (related_person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);

create unique index crm_person_relationships_unique
  on public.crm_person_relationships (person_id, related_person_id, relationship_type_id, valid_from) nulls not distinct;
create index crm_person_relationships_person  on public.crm_person_relationships (person_id, user_id);
create index crm_person_relationships_related on public.crm_person_relationships (related_person_id, user_id);
create index crm_person_relationships_type    on public.crm_person_relationships (relationship_type_id);

-- Guard: the type must be global or belong to the row's owner, and symmetric
-- pairs are put in canonical order. SECURITY INVOKER: a signed-in caller can see
-- only global and own types, so another user's custom type reads as unknown,
-- with the same message as a type that does not exist, so it is no oracle.
create function public.crm_relationship_guard()
returns trigger language plpgsql set search_path = '' as $fn$
declare
  t_owner uuid;
  t_sym   boolean;
  swap    uuid;
begin
  select user_id, is_symmetric into t_owner, t_sym
    from public.crm_relationship_types where id = new.relationship_type_id;
  if not found or (t_owner is not null and t_owner <> new.user_id) then
    raise exception 'unknown relationship type' using errcode = '23503';
  end if;
  if t_sym and new.person_id > new.related_person_id then
    swap := new.person_id;
    new.person_id := new.related_person_id;
    new.related_person_id := swap;
  end if;
  return new;
end $fn$;
revoke all on function public.crm_relationship_guard() from public, anon, authenticated;

create trigger trg_crm_person_relationships_05_guard
  before insert or update of person_id, related_person_id, relationship_type_id, user_id
  on public.crm_person_relationships
  for each row execute function public.crm_relationship_guard();

select public.crm_secure_owned_table('public.crm_person_relationships');

-- ---------------------------------------------------------------- both-ends view
-- security_invoker: the caller's RLS on the base tables applies; the view adds
-- no reach of its own. other_is = what other_person_id is TO person_id.
create view public.crm_relationships_expanded with (security_invoker = true) as
select r.id as relationship_id, r.user_id,
       r.related_person_id as person_id, r.person_id as other_person_id,
       t.label as other_is, t.code, t.category, t.is_symmetric,
       r.valid_from, r.valid_until, r.closeness, r.priority, r.context, r.is_confirmed, r.archived
  from public.crm_person_relationships r
  join public.crm_relationship_types t on t.id = r.relationship_type_id
union all
select r.id, r.user_id,
       r.person_id, r.related_person_id,
       coalesce(t.inverse_label, t.label), t.code, t.category, t.is_symmetric,
       r.valid_from, r.valid_until, r.closeness, r.priority, r.context, r.is_confirmed, r.archived
  from public.crm_person_relationships r
  join public.crm_relationship_types t on t.id = r.relationship_type_id;

revoke all on public.crm_relationships_expanded from public, anon, authenticated;
grant select on public.crm_relationships_expanded to authenticated;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_person_relationships');
  if not (select relrowsecurity from pg_class where oid = 'public.crm_relationship_types'::regclass) then
    raise exception 'A1: RLS off on crm_relationship_types';
  end if;
  if exists (select 1 from pg_policies where tablename = 'crm_relationship_types' and cmd <> 'SELECT'
              and coalesce(with_check, qual) like '%user_id IS NULL%') then
    raise exception 'A2: a write policy on crm_relationship_types admits global rows';
  end if;
  if has_table_privilege('anon', 'public.crm_relationship_types', 'select,insert,update,delete')
     or has_table_privilege('anon', 'public.crm_relationships_expanded', 'select') then
    raise exception 'A3: anon can reach relationship types or the expanded view';
  end if;
  if not exists (select 1 from pg_class where oid = 'public.crm_relationships_expanded'::regclass
                  and reloptions @> array['security_invoker=true']) then
    raise exception 'A4: crm_relationships_expanded is not security_invoker';
  end if;
  if (select count(*) from public.crm_relationship_types where user_id is null) <> 17 then
    raise exception 'A5: expected 17 global relationship types';
  end if;
end $chk$;;
