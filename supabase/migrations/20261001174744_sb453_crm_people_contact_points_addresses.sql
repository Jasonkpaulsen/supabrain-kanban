-- SB-453 (+ SB-463 provenance, SB-465 RLS): crm_people, crm_contact_points, crm_addresses.
-- Design: docs/adr/ADR-CRM-001-core-data-and-governance.md §2–§4.
--
-- One canonical person row per human. A contact point or address that stops
-- being true is marked is_current = false (with valid_until), never deleted, so
-- history is retained.
--
-- Same-owner integrity: children reference (person_id, user_id), not person_id
-- alone. A plain FK is checked as the table owner and bypasses RLS, so user B
-- could attach a row to user A's person by knowing its UUID, or probe whether a
-- UUID exists. The composite key makes a cross-owner link impossible for every
-- caller, service_role included.

-- ---------------------------------------------------------------- crm_people
create table public.crm_people (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  display_name   text not null check (btrim(display_name) <> '' and char_length(display_name) <= 200),
  given_name     text check (char_length(given_name) <= 100),
  middle_name    text check (char_length(middle_name) <= 100),
  family_name    text check (char_length(family_name) <= 100),
  preferred_name text check (char_length(preferred_name) <= 100),
  pronouns       text check (char_length(pronouns) <= 40),
  -- provenance (SB-463)
  source_type    text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref     text check (char_length(source_ref) <= 500),
  captured_at    timestamptz not null default now(),
  confidence     numeric(3,2) check (confidence between 0 and 1),
  confirmed_at   timestamptz,
  is_confirmed   boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  -- lifecycle
  archived       boolean not null default false,
  archived_at    timestamptz,
  meta           jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint crm_people_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_people_id_owner unique (id, user_id)
);
comment on table public.crm_people is
  'SB-453 / ADR-CRM-001. One canonical row per human; family/friend/business are relationship contexts, not tables.';

create index crm_people_user_name on public.crm_people (user_id, lower(display_name));

-- ---------------------------------------------------------------- crm_contact_points
create table public.crm_contact_points (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id        uuid not null,
  kind             text not null check (kind in ('email','phone','handle','url','other')),
  label            text check (char_length(label) <= 50),
  value            text not null check (btrim(value) <> '' and char_length(value) <= 320),
  -- Email/handle/url/other: case- and edge-space-insensitive. Phone: digits and +
  -- only, so '+1 (555) 010-0000' and '+15550100000' are the same number. No
  -- country code is inferred; that would be a guess.
  value_normalized text generated always as (
                     case kind when 'phone' then regexp_replace(value, '[^0-9+]', '', 'g')
                               else lower(btrim(value)) end) stored,
  is_preferred     boolean not null default false,
  is_current       boolean not null default true,
  valid_from       date,
  valid_until      date,
  source_type      text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref       text check (char_length(source_ref) <= 500),
  captured_at      timestamptz not null default now(),
  confidence       numeric(3,2) check (confidence between 0 and 1),
  confirmed_at     timestamptz,
  is_confirmed     boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  archived         boolean not null default false,
  archived_at      timestamptz,
  meta             jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint crm_contact_points_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_contact_points_validity check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint crm_contact_points_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_contact_points_unique_value unique (person_id, kind, value_normalized)
);

create index crm_contact_points_person on public.crm_contact_points (person_id, user_id);
-- "Who has this email/phone?"
create index crm_contact_points_lookup on public.crm_contact_points (user_id, kind, value_normalized);
-- At most one preferred, current, live value per person and kind.
create unique index crm_contact_points_one_preferred on public.crm_contact_points (person_id, kind)
  where is_preferred and is_current and not archived;

-- ---------------------------------------------------------------- crm_addresses
create table public.crm_addresses (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id     uuid not null,
  label         text check (char_length(label) <= 50),
  line1         text check (char_length(line1) <= 200),
  line2         text check (char_length(line2) <= 200),
  city          text check (char_length(city) <= 100),
  region        text check (char_length(region) <= 100),
  postal_code   text check (char_length(postal_code) <= 20),
  country_code  text check (country_code ~ '^[A-Z]{2}$'),
  is_preferred  boolean not null default false,
  is_current    boolean not null default true,
  valid_from    date,
  valid_until   date,
  source_type   text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref    text check (char_length(source_ref) <= 500),
  captured_at   timestamptz not null default now(),
  confidence    numeric(3,2) check (confidence between 0 and 1),
  confirmed_at  timestamptz,
  is_confirmed  boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  archived      boolean not null default false,
  archived_at   timestamptz,
  meta          jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint crm_addresses_not_empty check (coalesce(line1, city, region, postal_code) is not null),
  constraint crm_addresses_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_addresses_validity check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint crm_addresses_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);

create index crm_addresses_person on public.crm_addresses (person_id, user_id);
create unique index crm_addresses_one_preferred on public.crm_addresses (person_id)
  where is_preferred and is_current and not archived;

-- ---------------------------------------------------------------- triggers, RLS, grants
-- The owned-table standard (SB-462 migration): archive stamp, updated_at, audit
-- triggers, RLS with one owner policy per command, explicit grants, nothing to anon.
select public.crm_secure_owned_table('public.crm_people');
select public.crm_secure_owned_table('public.crm_contact_points');
select public.crm_secure_owned_table('public.crm_addresses');

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_people');
  perform public.crm_assert_owned_table('public.crm_contact_points');
  perform public.crm_assert_owned_table('public.crm_addresses');
end $chk$;;
