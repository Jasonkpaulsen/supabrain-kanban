-- SB-463 / SB-464 (+ SB-465): person facts and notes with provenance and a
-- sensitivity class, and the agent retrieval boundary. ADR-CRM-001 §2.2, §5.
--
-- Sensitivity is normal (default) / private / sensitive / highly_sensitive.
-- Nothing infers it: no trigger, classifier or default other than 'normal' ever
-- sets a class. Classification is a human act.
--
-- Restricted = sensitive + highly_sensitive. General agent retrieval goes through
-- crm_facts_for_agent(), which returns normal and private only. Reaching the
-- restricted classes takes an explicit include_restricted => true plus a reason
-- code, and the call is audited BEFORE any row is returned. A reason is a
-- snake_case code, not prose, so the audit log cannot become a place for content.

create table public.crm_facts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_id    uuid not null,
  fact_type    text not null check (fact_type ~ '^[a-z][a-z0-9_]{1,40}$'),
  value        text not null check (btrim(value) <> '' and char_length(value) <= 4000),
  sensitivity  text not null default 'normal'
               check (sensitivity in ('normal','private','sensitive','highly_sensitive')),
  valid_from   date,
  valid_until  date,
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
  constraint crm_facts_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_facts_validity check (valid_until is null or valid_from is null or valid_until >= valid_from),
  constraint crm_facts_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade
);
comment on table public.crm_facts is
  'SB-463/SB-464 / ADR-CRM-001. Extensible person facts and notes. sensitivity is never inferred. '
  'Agents read through crm_facts_for_agent(), which excludes sensitive and highly_sensitive by default.';

create index crm_facts_person on public.crm_facts (person_id, user_id);
create index crm_facts_user_sensitivity on public.crm_facts (user_id, sensitivity) where not archived;

-- The standard detects the sensitivity column and audits changes to it.
select public.crm_secure_owned_table('public.crm_facts');

-- ---------------------------------------------------------------- agent retrieval
-- SECURITY INVOKER: RLS still decides which rows exist for the caller. This
-- function narrows what a general retrieval returns; it never widens access.
create function public.crm_facts_for_agent(
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
    -- Audit first: if this insert fails, no restricted row is returned.
    perform public.crm_audit('restricted_read', 'crm_people', p_person_id, v_restricted,
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

revoke all on function public.crm_facts_for_agent(uuid, boolean, text) from public, anon;
grant execute on function public.crm_facts_for_agent(uuid, boolean, text) to authenticated, service_role;

do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_facts');
  -- The sensitivity audit trigger is wired to the right columns.
  if not exists (select 1 from pg_trigger where tgname = 'trg_crm_facts_90_audit_change'
                  and pg_get_triggerdef(oid) like '%UPDATE OF archived, sensitivity%') then
    raise exception 'A1: sensitivity changes on crm_facts are not audited';
  end if;
  -- No sensitivity is inferred: the only things that may touch the column are
  -- its default and the standard triggers, none of which assign it.
  if exists (select 1 from pg_proc p join pg_trigger t on t.tgfoid = p.oid
              where t.tgrelid = 'public.crm_facts'::regclass and not t.tgisinternal
                and p.prosrc ~* 'new\.sensitivity\s*:=') then
    raise exception 'A2: a trigger on crm_facts assigns sensitivity';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.crm_facts_for_agent(uuid,boolean,text)'::regprocedure) then
    raise exception 'A3: crm_facts_for_agent must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_facts_for_agent(uuid,boolean,text)', 'execute') then
    raise exception 'A4: anon can call crm_facts_for_agent';
  end if;
end $chk$;;
