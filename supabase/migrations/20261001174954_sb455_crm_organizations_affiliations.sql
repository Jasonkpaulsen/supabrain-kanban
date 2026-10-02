-- SB-455 (+ SB-463, SB-465): organizations and affiliations. ADR-CRM-001 §3.
--
-- Organization data lives on crm_organizations and is never copied onto the
-- person. A person holds any number of affiliations, current and historical;
-- one that ends gets an end_date rather than being deleted, so role/title,
-- department and start/end history are preserved.

create table public.crm_organizations (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name         text not null check (btrim(name) <> '' and char_length(name) <= 200),
  org_type     text not null default 'other'
               check (org_type in ('company','school','club','household','vendor','community','government','other')),
  website      text check (char_length(website) <= 300),
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
  constraint crm_organizations_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_organizations_id_owner unique (id, user_id)
);
-- Lookup, not uniqueness: two real organizations can share a name; finding
-- duplicates is SB-468's job, with a human deciding.
create index crm_organizations_user_name on public.crm_organizations (user_id, lower(name));

create table public.crm_affiliations (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id       uuid not null,
  organization_id uuid not null,
  role_title      text check (char_length(role_title) <= 150),
  department      text check (char_length(department) <= 150),
  start_date      date,
  end_date        date,
  -- "Current" is an open affiliation. Ending one is setting end_date.
  is_current      boolean generated always as (end_date is null) stored,
  source_type     text not null default 'manual' check (source_type in ('manual','import','agent','sync')),
  source_ref      text check (char_length(source_ref) <= 500),
  captured_at     timestamptz not null default now(),
  confidence      numeric(3,2) check (confidence between 0 and 1),
  confirmed_at    timestamptz,
  is_confirmed    boolean generated always as (source_type = 'manual' or confirmed_at is not null) stored,
  archived        boolean not null default false,
  archived_at     timestamptz,
  meta            jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint crm_affiliations_dates check (end_date is null or start_date is null or end_date >= start_date),
  constraint crm_affiliations_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_affiliations_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_affiliations_org_fk foreign key (organization_id, user_id)
    references public.crm_organizations (id, user_id) on delete cascade
);

create index crm_affiliations_person on public.crm_affiliations (person_id, user_id);
create index crm_affiliations_org    on public.crm_affiliations (organization_id, user_id);
-- "Where does X work / study now?" and "who is at Y now?"
create index crm_affiliations_current_by_person on public.crm_affiliations (user_id, person_id)
  where end_date is null and not archived;
create index crm_affiliations_current_by_org on public.crm_affiliations (user_id, organization_id)
  where end_date is null and not archived;

select public.crm_secure_owned_table('public.crm_organizations');
select public.crm_secure_owned_table('public.crm_affiliations');

do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_organizations');
  perform public.crm_assert_owned_table('public.crm_affiliations');
  -- Organization data is not duplicated onto people (SB-455 acceptance).
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'crm_people'
                and column_name ~ '(org|employer|company|title|department)') then
    raise exception 'A1: crm_people carries organization data';
  end if;
end $chk$;;
