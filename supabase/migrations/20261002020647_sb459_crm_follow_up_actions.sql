-- SB-459 (+ ADR-CRM-001 rules): follow-up actions. ADR-CRM-002 §2.
--
-- An action links to a person, an organization, an interaction, or any mix, and
-- at least one. completed_at is set if and only if the status is done: a trigger
-- stamps it on the transition and clears it on reopen, and a check makes an
-- inconsistent row impossible however it is written.

create table public.crm_actions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title           text not null check (btrim(title) <> '' and char_length(title) <= 200),
  notes           text check (char_length(notes) <= 4000),
  status          text not null default 'open' check (status in ('open','done','cancelled')),
  priority        text not null default 'normal' check (priority in ('urgent','high','normal','low')),
  due_at          timestamptz,
  completed_at    timestamptz,
  person_id       uuid,
  organization_id uuid,
  interaction_id  uuid,
  sensitivity     text not null default 'normal'
                  check (sensitivity in ('normal','private','sensitive','highly_sensitive')),
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
  constraint crm_actions_linked check (num_nonnulls(person_id, organization_id, interaction_id) >= 1),
  constraint crm_actions_completed_iff_done check ((status = 'done') = (completed_at is not null)),
  constraint crm_actions_confidence_required check (source_type = 'manual' or confidence is not null),
  constraint crm_actions_person_fk foreign key (person_id, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_actions_org_fk foreign key (organization_id, user_id)
    references public.crm_organizations (id, user_id) on delete cascade,
  constraint crm_actions_interaction_fk foreign key (interaction_id, user_id)
    references public.crm_interactions (id, user_id) on delete cascade
);
comment on table public.crm_actions is
  'SB-459 / ADR-CRM-002. Follow-ups linked to a person, organization and/or interaction. '
  'completed_at is set iff status = done.';

-- The open queue by due date, and per-target lookups
create index crm_actions_user_status_due on public.crm_actions (user_id, status, due_at);
create index crm_actions_person      on public.crm_actions (person_id, user_id)      where person_id is not null;
create index crm_actions_org         on public.crm_actions (organization_id, user_id) where organization_id is not null;
create index crm_actions_interaction on public.crm_actions (interaction_id, user_id)  where interaction_id is not null;

-- completed_at follows status. Runs before the archive stamp (05 < 10).
create function public.crm_actions_stamp_completion()
returns trigger language plpgsql set search_path = '' as $fn$
begin
  if new.status = 'done' then
    if tg_op = 'INSERT' or old.status is distinct from 'done' then
      new.completed_at := coalesce(new.completed_at, now());
    end if;
  elsif tg_op = 'UPDATE' and old.status = 'done' then
    -- reopened or cancelled: it is no longer complete
    new.completed_at := null;
  end if;
  return new;
end $fn$;
revoke all on function public.crm_actions_stamp_completion() from public, anon, authenticated;

create trigger trg_crm_actions_05_completion
  before insert or update of status, completed_at on public.crm_actions
  for each row execute function public.crm_actions_stamp_completion();

select public.crm_secure_owned_table('public.crm_actions');

-- ---------------------------------------------------------------- follow-up from an interaction
-- SECURITY INVOKER: the caller can only see its own interaction, so another
-- user's interaction reads as not found. The person defaults to the interaction's
-- only person participant (when there is exactly one). Sensitivity defaults to the
-- interaction's own class: copying a class a human already chose is not
-- inference, and it stops a follow-up leaking a sensitive interaction at a lower
-- class. An explicit argument overrides both defaults.
create function public.crm_create_follow_up(
  p_interaction_id uuid,
  p_title          text,
  p_due_at         timestamptz default null,
  p_priority       text        default 'normal',
  p_person_id      uuid        default null,
  p_sensitivity    text        default null
) returns uuid
language plpgsql security invoker set search_path = '' as $fn$
declare
  v_int    public.crm_interactions%rowtype;
  v_person uuid := p_person_id;
  v_id     uuid;
begin
  select * into v_int from public.crm_interactions where id = p_interaction_id and not archived;
  if not found then
    raise exception 'interaction not found' using errcode = 'P0002';
  end if;
  if v_person is null then
    select min(person_id::text)::uuid into v_person
      from public.crm_interaction_participants
     where interaction_id = p_interaction_id and person_id is not null and not archived
    having count(*) = 1;
  end if;

  insert into public.crm_actions (user_id, title, due_at, priority, person_id, interaction_id, sensitivity)
  values (v_int.user_id, p_title, p_due_at, coalesce(p_priority, 'normal'), v_person, v_int.id,
          coalesce(p_sensitivity, v_int.sensitivity))
  returning id into v_id;
  return v_id;
end $fn$;

revoke all on function public.crm_create_follow_up(uuid, text, timestamptz, text, uuid, text) from public, anon;
grant execute on function public.crm_create_follow_up(uuid, text, timestamptz, text, uuid, text) to authenticated, service_role;

do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_actions');
  if (select prosecdef from pg_proc
       where oid = 'public.crm_create_follow_up(uuid,text,timestamptz,text,uuid,text)'::regprocedure) then
    raise exception 'A1: crm_create_follow_up must be SECURITY INVOKER';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_crm_actions_90_audit_change'
                  and pg_get_triggerdef(oid) like '%UPDATE OF archived, sensitivity%') then
    raise exception 'A2: sensitivity changes on crm_actions are not audited';
  end if;
end $chk$;;
