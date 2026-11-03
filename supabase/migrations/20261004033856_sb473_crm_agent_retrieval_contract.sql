-- SB-473 (ADR-CRM-004 §2): the least-privilege retrieval contract for agents.
--
-- 1. `agent_read` joins the audit vocabulary. Every per-person agent read is
--    reason-coded and audited before it returns data (actor_kind = agent,
--    entity_type = crm_people, entity_id = the person, entity_count = items).
-- 2. crm_person_card_for_agent: identity, cadence and priority, plus which
--    contact KINDS exist and which are marked preferred. Never a contact value.
-- 3. Assertions that make the contract checkable in the catalog: every crm_
--    view is security_invoker, every crm_ function authenticated can run is
--    SECURITY INVOKER, nothing is reachable by anon, and the *_for_agent set is
--    pinned. Owner rights are deliberately not used (ADR-CRM-003 §6).

alter table public.crm_audit_log drop constraint crm_audit_log_action_check;
alter table public.crm_audit_log add constraint crm_audit_log_action_check
  check (action in ('merge','export','bulk_import','sensitivity_change','delete','archive',
                    'unarchive','restricted_read','agent_read'));

create or replace function public.crm_audit(p_action text, p_entity_type text,
  p_entity_id uuid default null, p_entity_count integer default 1,
  p_outcome text default 'succeeded', p_reason_code text default null,
  p_actor_kind text default null, p_owner uuid default null)
returns uuid
language plpgsql
set search_path = '' as $fn$
declare
  v_uid   uuid := auth.uid();
  v_owner uuid;
  v_id    uuid;
begin
  if p_action not in ('merge','export','bulk_import','restricted_read','agent_read') then
    raise exception 'crm_audit: % is recorded by triggers, not by callers', p_action
      using errcode = '22023';
  end if;
  if v_uid is not null and p_owner is not null and p_owner <> v_uid then
    raise exception 'crm_audit: a signed-in caller can only audit its own data'
      using errcode = '42501';
  end if;
  v_owner := coalesce(v_uid, p_owner);
  if v_owner is null then
    raise exception 'crm_audit: no owner (pass p_owner when calling without a user session)'
      using errcode = '22023';
  end if;

  insert into public.crm_audit_log
    (user_id, actor_id, actor_kind, action, entity_type, entity_id, entity_count, outcome, reason_code)
  values
    (v_owner, v_uid,
     coalesce(p_actor_kind, case when v_uid is null then 'system' else 'user' end),
     p_action, p_entity_type, p_entity_id, coalesce(p_entity_count, 1),
     coalesce(p_outcome, 'succeeded'), p_reason_code)
  returning id into v_id;
  return v_id;
end $fn$;

create or replace function public.crm_person_card_for_agent(p_person_id uuid, p_reason text)
returns table (id uuid, display_name text, preferred_name text, given_name text, family_name text,
               pronouns text, relationship_priority smallint, contact_cadence_days integer,
               confirmed boolean, source_type text, contact_kinds text[], preferred_contact_kinds text[])
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'agent CRM retrieval needs a reason code (snake_case, 3-64 chars)'
      using errcode = '22023';
  end if;
  -- Unknown, archived (which includes merged) and other owners' people are all
  -- "not found", with one message, so a caller cannot probe for existence.
  if v_uid is null or not exists (select 1 from public.crm_people p
                                   where p.id = p_person_id and p.user_id = v_uid and not p.archived) then
    raise exception 'CRM person not found' using errcode = 'P0002';
  end if;
  -- Audit first: if this insert fails, nothing is returned.
  perform public.crm_audit('agent_read', 'crm_people', p_person_id, 1, 'succeeded', p_reason, 'agent', v_uid);

  return query
    select p.id, p.display_name, p.preferred_name, p.given_name, p.family_name, p.pronouns,
           p.relationship_priority, p.contact_cadence_days, p.is_confirmed, p.source_type,
           coalesce((select array_agg(distinct c.kind order by c.kind) from public.crm_contact_points c
                      where c.person_id = p.id and c.user_id = v_uid and c.is_current and not c.archived), '{}'),
           coalesce((select array_agg(distinct c.kind order by c.kind) from public.crm_contact_points c
                      where c.person_id = p.id and c.user_id = v_uid and c.is_current and c.is_preferred
                        and not c.archived), '{}')
      from public.crm_people p
     where p.id = p_person_id and p.user_id = v_uid;
end $fn$;

revoke all on function public.crm_person_card_for_agent(uuid, text) from public, anon;
grant execute on function public.crm_person_card_for_agent(uuid, text) to authenticated, service_role;

do $chk$
declare n int;
begin
  -- A1: agent_read is accepted by the log and by crm_audit
  if not exists (select 1 from pg_constraint where conname = 'crm_audit_log_action_check'
                  and pg_get_constraintdef(oid) like '%agent_read%') then
    raise exception 'A1: agent_read missing from the audit vocabulary';
  end if;
  -- A2: every crm_ view runs with the caller's rights
  select count(*) into n from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'v' and c.relname like 'crm\_%'
     and not coalesce(c.reloptions, '{}') @> array['security_invoker=true'];
  if n > 0 then raise exception 'A2: % crm_ view(s) are not security_invoker', n; end if;
  -- A3: no crm_ function that authenticated can run uses owner rights
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'execute');
  if n > 0 then raise exception 'A3: % SECURITY DEFINER crm_ function(s) are callable by authenticated', n; end if;
  -- A4: nothing for anon
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'crm\_%' and has_function_privilege('anon', p.oid, 'execute');
  if n > 0 then raise exception 'A4: anon can execute % crm_ function(s)', n; end if;
  -- A5: the *_for_agent set is exactly the documented one (ADR-CRM-004 §2.1)
  if (select array_agg(p.proname order by p.proname) from pg_proc p join pg_namespace s on s.oid = p.pronamespace
       where s.nspname = 'public' and p.proname like 'crm\_%\_for\_agent')
     <> array['crm_facts_for_agent','crm_interactions_for_agent','crm_person_card_for_agent']::name[] then
    raise exception 'A5: the *_for_agent set differs from ADR-CRM-004 §2.1';
  end if;
  -- A6: the card itself
  if (select prosecdef from pg_proc where oid = 'public.crm_person_card_for_agent(uuid,text)'::regprocedure)
     or not has_function_privilege('authenticated', 'public.crm_person_card_for_agent(uuid,text)', 'execute') then
    raise exception 'A6: crm_person_card_for_agent must be invoker and executable by authenticated';
  end if;
end $chk$;
