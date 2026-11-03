-- SB-460 (+ ADR-CRM-001 rules): interactions and their participants. ADR-CRM-002 §2, §4.
--
-- One row per interaction, whatever the kind. People and organizations involved
-- are participants, any number of them, each through a composite same-owner FK.
-- Sensitivity is the ADR-CRM-001 §5 class: default normal, never inferred, and
-- changes are audited by the owned-table standard (it detects the column).

create table public.crm_interactions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references auth.users(id) on delete cascade,
  interaction_type text not null check (interaction_type in
                     ('call','meeting','email','message','meal','event','gift','introduction','note','other')),
  -- null for kinds that have no direction (a note, a shared meal)
  direction        text check (direction in ('inbound','outbound','mutual')),
  occurred_at      timestamptz not null default now(),
  ended_at         timestamptz,
  title            text check (char_length(title) <= 200),
  summary          text check (char_length(summary) <= 8000),
  location         text check (char_length(location) <= 200),
  sensitivity      text not null default 'normal'
                   check (sensitivity in ('normal','private','sensitive','highly_sensitive')),
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
  constraint crm_interactions_range check (ended_at is null or ended_at >= occurred_at),
  constraint crm_interactions_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_interactions_id_owner unique (id, user_id)
);
comment on table public.crm_interactions is
  'SB-460 / ADR-CRM-002. One row per call, meeting, email, message, meal, event, gift, introduction or note. '
  'sensitivity is never inferred; agents read through crm_interactions_for_agent().';

-- "History, newest first" for the owner
create index crm_interactions_user_time on public.crm_interactions (user_id, occurred_at desc);

create table public.crm_interaction_participants (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  interaction_id  uuid not null,
  person_id       uuid,
  organization_id uuid,
  role            text not null default 'participant' check (role in
                    ('participant','organizer','sender','recipient','introducer','introduced','giver','receiver','other')),
  archived        boolean not null default false,
  archived_at     timestamptz,
  meta            jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint crm_interaction_participants_one_target check (num_nonnulls(person_id, organization_id) = 1),
  constraint crm_interaction_participants_interaction_fk foreign key (interaction_id, user_id)
    references public.crm_interactions (id, user_id) on delete cascade,
  constraint crm_interaction_participants_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_interaction_participants_org_fk foreign key (organization_id, user_id)
    references public.crm_organizations (id, user_id) on delete cascade
);

create unique index crm_interaction_participants_person_once
  on public.crm_interaction_participants (interaction_id, person_id) where person_id is not null;
create unique index crm_interaction_participants_org_once
  on public.crm_interaction_participants (interaction_id, organization_id) where organization_id is not null;
create index crm_interaction_participants_user on public.crm_interaction_participants (user_id);
create index crm_interaction_participants_interaction on public.crm_interaction_participants (interaction_id, user_id);
-- "Everything with person X", which also drives last-contact signals (SB-458)
create index crm_interaction_participants_person on public.crm_interaction_participants (person_id, user_id)
  where person_id is not null;
create index crm_interaction_participants_org on public.crm_interaction_participants (organization_id, user_id)
  where organization_id is not null;

select public.crm_secure_owned_table('public.crm_interactions');
select public.crm_secure_owned_table('public.crm_interaction_participants');

-- ---------------------------------------------------------------- agent retrieval
-- Mirrors crm_facts_for_agent (ADR-CRM-001 §5). SECURITY INVOKER: it narrows what
-- a general retrieval returns and never widens access.
create function public.crm_interactions_for_agent(
  p_person_id          uuid,
  p_include_restricted boolean default false,
  p_reason             text    default null
) returns table (
  id uuid, interaction_type text, direction text, occurred_at timestamptz, ended_at timestamptz,
  title text, summary text, sensitivity text, source_type text, confidence numeric, is_confirmed boolean
)
language plpgsql security invoker set search_path = '' as $fn$
declare
  v_owner      uuid;
  v_restricted int;
begin
  if p_include_restricted then
    if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
      raise exception 'restricted CRM retrieval needs a reason code (snake_case, 3-64 chars)'
        using errcode = '22023';
    end if;
    select p.user_id into v_owner from public.crm_people p where p.id = p_person_id;
    select count(distinct i.id) into v_restricted
      from public.crm_interactions i
      join public.crm_interaction_participants ip on ip.interaction_id = i.id
     where ip.person_id = p_person_id and not i.archived and not ip.archived
       and i.sensitivity in ('sensitive','highly_sensitive');
    -- Audit first: if this insert fails, no restricted row is returned.
    perform public.crm_audit('restricted_read', 'crm_interactions', p_person_id, v_restricted,
                             'succeeded', p_reason, 'agent', coalesce(v_owner, auth.uid()));
  end if;

  return query
    -- A person is a participant at most once per interaction (unique index),
    -- so the join cannot repeat an interaction.
    select i.id, i.interaction_type, i.direction, i.occurred_at, i.ended_at, i.title, i.summary,
           i.sensitivity, i.source_type, i.confidence, i.is_confirmed
      from public.crm_interactions i
      join public.crm_interaction_participants ip on ip.interaction_id = i.id
     where ip.person_id = p_person_id
       and not i.archived and not ip.archived
       and (p_include_restricted or i.sensitivity in ('normal','private'))
     order by i.occurred_at desc, i.id;
end $fn$;

revoke all on function public.crm_interactions_for_agent(uuid, boolean, text) from public, anon;
grant execute on function public.crm_interactions_for_agent(uuid, boolean, text) to authenticated, service_role;

-- ---------------------------------------------------------------- restricted-read convention
-- ADR-CRM-002 §4: entity_type is the table that was read, entity_id the person.
-- crm_facts_for_agent used 'crm_people', which would make fact reads and
-- interaction reads indistinguishable in the audit log. Same signature and body
-- otherwise, so existing grants carry over.
create or replace function public.crm_facts_for_agent(
  p_person_id          uuid,
  p_include_restricted boolean default false,
  p_reason             text    default null
) returns table (
  id uuid, fact_type text, value text, sensitivity text,
  source_type text, confidence numeric, is_confirmed boolean, captured_at timestamptz,
  valid_from date, valid_until date
)
language plpgsql security invoker set search_path = '' as $fn$
declare
  v_owner      uuid;
  v_restricted int;
begin
  if p_include_restricted then
    if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
      raise exception 'restricted CRM retrieval needs a reason code (snake_case, 3-64 chars)'
        using errcode = '22023';
    end if;
    select p.user_id into v_owner from public.crm_people p where p.id = p_person_id;
    select count(*) into v_restricted from public.crm_facts f
     where f.person_id = p_person_id and not f.archived
       and f.sensitivity in ('sensitive','highly_sensitive');
    perform public.crm_audit('restricted_read', 'crm_facts', p_person_id, v_restricted,
                             'succeeded', p_reason, 'agent', coalesce(v_owner, auth.uid()));
  end if;

  return query
    select f.id, f.fact_type, f.value, f.sensitivity, f.source_type, f.confidence,
           f.is_confirmed, f.captured_at, f.valid_from, f.valid_until
      from public.crm_facts f
     where f.person_id = p_person_id
       and not f.archived
       and (p_include_restricted or f.sensitivity in ('normal','private'))
     order by f.fact_type, f.captured_at;
end $fn$;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_interactions');
  perform public.crm_assert_owned_table('public.crm_interaction_participants');
  if not exists (select 1 from pg_trigger where tgname = 'trg_crm_interactions_90_audit_change'
                  and pg_get_triggerdef(oid) like '%UPDATE OF archived, sensitivity%') then
    raise exception 'A1: sensitivity changes on crm_interactions are not audited';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.crm_interactions_for_agent(uuid,boolean,text)'::regprocedure)
     or (select prosecdef from pg_proc where oid = 'public.crm_facts_for_agent(uuid,boolean,text)'::regprocedure) then
    raise exception 'A2: agent retrieval functions must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_interactions_for_agent(uuid,boolean,text)', 'execute')
     or has_function_privilege('anon', 'public.crm_facts_for_agent(uuid,boolean,text)', 'execute') then
    raise exception 'A3: anon can call an agent retrieval function';
  end if;
  if not has_function_privilege('authenticated', 'public.crm_facts_for_agent(uuid,boolean,text)', 'execute') then
    raise exception 'A4: replacing crm_facts_for_agent lost the authenticated grant';
  end if;
  if (select prosrc from pg_proc where oid = 'public.crm_facts_for_agent(uuid,boolean,text)'::regprocedure)
     not like '%''restricted_read'', ''crm_facts''%' then
    raise exception 'A5: crm_facts_for_agent does not follow the restricted-read convention';
  end if;
end $chk$;;
