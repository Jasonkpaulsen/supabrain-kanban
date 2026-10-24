-- SB-456 (+ SB-463, SB-465): circles/groups, tags, important dates. ADR-CRM-001 §3.
--
-- Family, Close Friends, ELC, Vendors, School Parents and custom circles are all
-- just crm_groups rows. A person joins any number of them without being copied.
-- No group is seeded: circles are the owner's to name.

-- ---------------------------------------------------------------- groups
create table public.crm_groups (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (btrim(name) <> '' and char_length(name) <= 100),
  description text check (char_length(description) <= 500),
  color       text check (color ~ '^#[0-9a-fA-F]{6}$'),
  archived    boolean not null default false,
  archived_at timestamptz,
  meta        jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint crm_groups_id_owner unique (id, user_id)
);
create unique index crm_groups_user_name on public.crm_groups (user_id, lower(name)) where not archived;

create table public.crm_group_members (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  group_id    uuid not null,
  person_id   uuid not null,
  role        text check (char_length(role) <= 60),
  archived    boolean not null default false,
  archived_at timestamptz,
  meta        jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint crm_group_members_unique unique (group_id, person_id),
  constraint crm_group_members_group_fk foreign key (group_id, user_id)
    references public.crm_groups (id, user_id) on delete cascade,
  constraint crm_group_members_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);
create index crm_group_members_person on public.crm_group_members (person_id, user_id);
create index crm_group_members_group  on public.crm_group_members (group_id, user_id);

-- ---------------------------------------------------------------- tags
create table public.crm_tags (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (btrim(name) <> '' and char_length(name) <= 60),
  color       text check (color ~ '^#[0-9a-fA-F]{6}$'),
  archived    boolean not null default false,
  archived_at timestamptz,
  meta        jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint crm_tags_id_owner unique (id, user_id)
);
create unique index crm_tags_user_name on public.crm_tags (user_id, lower(name)) where not archived;

-- A tag points at exactly one person OR one organization. Separate nullable
-- columns with composite FKs, rather than a polymorphic (type, id) pair, so the
-- database still enforces existence and same ownership. A composite FK with a
-- null member is not checked (MATCH SIMPLE), which is what lets the unused side
-- stay null.
create table public.crm_entity_tags (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tag_id          uuid not null,
  person_id       uuid,
  organization_id uuid,
  archived        boolean not null default false,
  archived_at     timestamptz,
  meta            jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint crm_entity_tags_one_target check (num_nonnulls(person_id, organization_id) = 1),
  constraint crm_entity_tags_tag_fk foreign key (tag_id, user_id)
    references public.crm_tags (id, user_id) on delete cascade,
  constraint crm_entity_tags_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_entity_tags_org_fk foreign key (organization_id, user_id)
    references public.crm_organizations (id, user_id) on delete cascade
);
create unique index crm_entity_tags_person_unique on public.crm_entity_tags (tag_id, person_id) where person_id is not null;
create unique index crm_entity_tags_org_unique    on public.crm_entity_tags (tag_id, organization_id) where organization_id is not null;
create index crm_entity_tags_tag    on public.crm_entity_tags (tag_id, user_id);
create index crm_entity_tags_person on public.crm_entity_tags (person_id, user_id) where person_id is not null;
create index crm_entity_tags_org    on public.crm_entity_tags (organization_id, user_id) where organization_id is not null;

-- ---------------------------------------------------------------- important dates
-- month/day/year rather than one date, so "birthday 14 March, year unknown" is
-- representable without inventing a year.
create table public.crm_important_dates (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id    uuid not null,
  kind         text not null check (kind in ('birthday','anniversary','milestone','memorial','other')),
  label        text check (char_length(label) <= 100),
  month        smallint not null check (month between 1 and 12),
  day          smallint not null check (day between 1 and 31),
  year         integer check (year between 1800 and 2200),
  recurrence   text not null default 'yearly' check (recurrence in ('none','yearly')),
  source_type  text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref   text check (char_length(source_ref) <= 500),
  captured_at  timestamptz not null default now(),
  confidence   numeric(3,2) check (confidence between 0 and 1),
  confirmed_at timestamptz,
  is_confirmed boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  archived     boolean not null default false,
  archived_at  timestamptz,
  meta         jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- A real calendar date: Feb 30 and Apr 31 are refused. Without a year it is
  -- checked against leap year 2000, so Feb 29 is allowed.
  constraint crm_important_dates_real_date check (make_date(coalesce(year, 2000), month, day) is not null),
  constraint crm_important_dates_one_off_needs_year check (recurrence = 'yearly' or year is not null),
  constraint crm_important_dates_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_important_dates_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);
create index crm_important_dates_person   on public.crm_important_dates (person_id, user_id);
create index crm_important_dates_calendar on public.crm_important_dates (user_id, month, day) where not archived;

-- Next occurrence on or after p_from. A yearly Feb 29 falls on Feb 28 in common
-- years. A one-off date returns itself if it is still ahead, else null. A yearly
-- date with a known year never returns a date before that year.
create function public.crm_next_occurrence(
  p_month smallint, p_day smallint, p_year integer, p_recurrence text, p_from date default current_date
) returns date language plpgsql stable set search_path = '' as $fn$
declare
  y int := extract(year from p_from)::int;
  d date;
begin
  if p_recurrence = 'none' then
    d := make_date(p_year, p_month, p_day);
    return case when d >= p_from then d end;
  end if;
  if p_year is not null and y < p_year then
    y := p_year;
  end if;
  for i in 0..1 loop
    d := case when p_month = 2 and p_day = 29
                   and not ((y + i) % 4 = 0 and ((y + i) % 100 <> 0 or (y + i) % 400 = 0))
              then make_date(y + i, 2, 28)
              else make_date(y + i, p_month, p_day) end;
    if d >= p_from then return d; end if;
  end loop;
  return null;
end $fn$;
revoke all on function public.crm_next_occurrence(smallint, smallint, integer, text, date) from public, anon;
grant execute on function public.crm_next_occurrence(smallint, smallint, integer, text, date) to authenticated;

select public.crm_secure_owned_table('public.crm_groups');
select public.crm_secure_owned_table('public.crm_group_members');
select public.crm_secure_owned_table('public.crm_tags');
select public.crm_secure_owned_table('public.crm_entity_tags');
select public.crm_secure_owned_table('public.crm_important_dates');

do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_groups');
  perform public.crm_assert_owned_table('public.crm_group_members');
  perform public.crm_assert_owned_table('public.crm_tags');
  perform public.crm_assert_owned_table('public.crm_entity_tags');
  perform public.crm_assert_owned_table('public.crm_important_dates');
  -- The leap-day rule, checked here so a broken function cannot record.
  if public.crm_next_occurrence(2::smallint, 29::smallint, null, 'yearly', date '2027-01-01') <> date '2027-02-28'
     or public.crm_next_occurrence(2::smallint, 29::smallint, null, 'yearly', date '2028-01-01') <> date '2028-02-29'
     or public.crm_next_occurrence(3::smallint, 14::smallint, null, 'yearly', date '2026-12-01') <> date '2027-03-14'
     or public.crm_next_occurrence(6::smallint, 1::smallint, 2020, 'none', date '2026-01-01') is not null then
    raise exception 'A1: crm_next_occurrence is wrong';
  end if;
end $chk$;;
