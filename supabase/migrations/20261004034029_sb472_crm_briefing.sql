-- SB-472 (ADR-CRM-004 §3): the data for a relationship briefing on one person.
--
-- crm_briefing(person, reason) returns one bounded, source-aware jsonb document:
-- person, signals, relationships, affiliations, recent_interactions,
-- open_follow_ups, upcoming_dates, facts, and `omitted` (what the bounds cut and
-- how many restricted items were left out). Every item carries its row id, and
-- every stored assertion its `confirmed` flag and `source_type`, so an agent can
-- cite sources and never present an unconfirmed relationship or fact as fact.
-- Normal and private classes only; restricted follow-up titles read "(restricted)".
-- It follows the SB-473 contract: SECURITY INVOKER plus an explicit owner filter,
-- a required reason code, and an agent_read audit row before anything returns.

create or replace function public.crm_briefing(p_person_id uuid, p_reason text)
returns jsonb
language plpgsql volatile security invoker
set search_path = '' as $fn$
declare
  v_uid        uuid := auth.uid();
  c_text       constant int := 280;
  c_rel        constant int := 20;
  c_aff        constant int := 10;
  c_int        constant int := 5;
  c_act        constant int := 10;
  c_dates      constant int := 5;
  c_date_days  constant int := 60;
  c_facts      constant int := 20;
  v_person     jsonb;
  v_signals    jsonb;
  v_rel        jsonb;  n_rel  int;
  v_aff        jsonb;  n_aff  int;
  v_int        jsonb;  n_int  int;  n_int_restricted int;
  v_act        jsonb;  n_act  int;
  v_dates      jsonb;  n_dates int;
  v_facts      jsonb;  n_facts int; n_facts_restricted int;
  v_items      int;
begin
  if p_reason is null or p_reason !~ '^[a-z0-9_]{3,64}$' then
    raise exception 'agent CRM retrieval needs a reason code (snake_case, 3-64 chars)'
      using errcode = '22023';
  end if;
  if v_uid is null or not exists (select 1 from public.crm_people p
                                   where p.id = p_person_id and p.user_id = v_uid and not p.archived) then
    raise exception 'CRM person not found' using errcode = 'P0002';
  end if;

  select jsonb_build_object(
           'id', p.id, 'display_name', p.display_name, 'preferred_name', p.preferred_name,
           'given_name', p.given_name, 'family_name', p.family_name, 'pronouns', p.pronouns,
           'relationship_priority', p.relationship_priority, 'contact_cadence_days', p.contact_cadence_days,
           'confirmed', p.is_confirmed, 'source_type', p.source_type,
           'contact_kinds', coalesce((select jsonb_agg(distinct c.kind) from public.crm_contact_points c
                                       where c.person_id = p.id and c.user_id = v_uid and c.is_current and not c.archived), '[]'),
           'preferred_contact_kinds', coalesce((select jsonb_agg(distinct c.kind) from public.crm_contact_points c
                                       where c.person_id = p.id and c.user_id = v_uid and c.is_current
                                         and c.is_preferred and not c.archived), '[]'))
    into v_person
    from public.crm_people p where p.id = p_person_id and p.user_id = v_uid;

  select jsonb_build_object(
           'last_contact_at', s.last_contact_at, 'last_contact_type', s.last_contact_type,
           'days_since_contact', s.days_since_contact, 'next_contact_due_at', s.next_contact_due_at,
           'is_contact_overdue', s.is_contact_overdue, 'days_overdue', s.days_overdue,
           'explanation', s.explanation)
    into v_signals
    from public.crm_contact_signals s where s.person_id = p_person_id and s.user_id = v_uid;

  -- relationships: live, in date, both people live; labelled from this person's side
  with r as (
    select e.relationship_id, e.other_person_id, o.display_name as other_name, e.other_is, e.code,
           e.category, e.closeness, e.priority, left(e.context, c_text) as context,
           e.is_confirmed, pr.source_type, pr.confidence
      from public.crm_relationships_expanded e
      join public.crm_person_relationships pr on pr.id = e.relationship_id
      join public.crm_people o on o.id = e.other_person_id and not o.archived
     where e.person_id = p_person_id and e.user_id = v_uid and not e.archived
       and (e.valid_from is null or e.valid_from <= current_date)
       and (e.valid_until is null or e.valid_until >= current_date))
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.relationship_id, 'other_person_id', x.other_person_id, 'other_name', x.other_name,
           'other_is', x.other_is, 'code', x.code, 'category', x.category, 'closeness', x.closeness,
           'context', x.context, 'confirmed', x.is_confirmed, 'source_type', x.source_type,
           'confidence', x.confidence)
           order by x.priority nulls last, x.closeness desc nulls last, x.other_name)
           filter (where x.rn <= c_rel), '[]')
    into n_rel, v_rel
    from (select r.*, row_number() over (order by r.priority nulls last, r.closeness desc nulls last, r.other_name) as rn
            from r) x;

  -- affiliations: current first, then most recent
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'organization_id', x.organization_id, 'organization', x.name,
           'role_title', x.role_title, 'department', x.department, 'is_current', x.is_current,
           'start_date', x.start_date, 'end_date', x.end_date,
           'confirmed', x.is_confirmed, 'source_type', x.source_type, 'confidence', x.confidence)
           order by x.rn) filter (where x.rn <= c_aff), '[]')
    into n_aff, v_aff
    from (select a.*, o.name,
                 row_number() over (order by a.is_current desc, a.start_date desc nulls last, o.name) as rn
            from public.crm_affiliations a
            join public.crm_organizations o on o.id = a.organization_id and not o.archived
           where a.person_id = p_person_id and a.user_id = v_uid and not a.archived) x;

  -- recent interactions: already happened, normal/private only, newest first
  select count(*) filter (where i.sensitivity in ('sensitive','highly_sensitive'))
    into n_int_restricted
    from public.crm_interactions i
    join public.crm_interaction_participants ip on ip.interaction_id = i.id and not ip.archived
   where ip.person_id = p_person_id and i.user_id = v_uid and not i.archived and i.occurred_at <= now();
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'interaction_type', x.interaction_type, 'direction', x.direction,
           'occurred_at', x.occurred_at, 'title', left(x.title, c_text), 'summary', left(x.summary, c_text),
           'confirmed', x.is_confirmed, 'source_type', x.source_type)
           order by x.rn) filter (where x.rn <= c_int), '[]')
    into n_int, v_int
    from (select i.*, row_number() over (order by i.occurred_at desc, i.id) as rn
            from public.crm_interactions i
            join public.crm_interaction_participants ip on ip.interaction_id = i.id and not ip.archived
           where ip.person_id = p_person_id and i.user_id = v_uid and not i.archived
             and i.occurred_at <= now() and i.sensitivity in ('normal','private')) x;

  -- open follow-ups: soonest due first; restricted titles masked
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'title', case when x.sensitivity in ('sensitive','highly_sensitive') then '(restricted)'
                         else left(x.title, c_text) end,
           'restricted', x.sensitivity in ('sensitive','highly_sensitive'),
           'due_at', x.due_at, 'priority', x.priority,
           'overdue', x.due_at is not null and x.due_at < now(),
           'confirmed', x.is_confirmed, 'source_type', x.source_type)
           order by x.rn) filter (where x.rn <= c_act), '[]')
    into n_act, v_act
    from (select a.*, row_number() over (
                   order by a.due_at nulls last,
                            array_position(array['urgent','high','normal','low'], a.priority), a.id) as rn
            from public.crm_actions a
           where a.person_id = p_person_id and a.user_id = v_uid and not a.archived and a.status = 'open') x;

  -- upcoming dates in the window
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.date_id, 'kind', x.kind, 'label', x.label, 'next_date', x.next_date,
           'days_until', x.days_until, 'years', x.years)
           order by x.rn) filter (where x.rn <= c_dates), '[]')
    into n_dates, v_dates
    from (select d.*, row_number() over (order by d.days_until, d.kind) as rn
            from public.crm_upcoming_dates(c_date_days) d
           where d.person_id = p_person_id) x;

  -- facts: normal/private only
  select count(*) into n_facts_restricted
    from public.crm_facts f
   where f.person_id = p_person_id and f.user_id = v_uid and not f.archived
     and f.sensitivity in ('sensitive','highly_sensitive');
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id, 'fact_type', x.fact_type, 'value', left(x.value, c_text),
           'confirmed', x.is_confirmed, 'source_type', x.source_type, 'confidence', x.confidence,
           'valid_from', x.valid_from, 'valid_until', x.valid_until)
           order by x.rn) filter (where x.rn <= c_facts), '[]')
    into n_facts, v_facts
    from (select f.*, row_number() over (order by f.is_confirmed desc, f.fact_type, f.captured_at desc, f.id) as rn
            from public.crm_facts f
           where f.person_id = p_person_id and f.user_id = v_uid and not f.archived
             and f.sensitivity in ('normal','private')) x;

  v_items := 1 + jsonb_array_length(v_rel) + jsonb_array_length(v_aff) + jsonb_array_length(v_int)
           + jsonb_array_length(v_act) + jsonb_array_length(v_dates) + jsonb_array_length(v_facts);
  -- Audit first: if this insert fails, nothing is returned.
  perform public.crm_audit('agent_read', 'crm_people', p_person_id, v_items, 'succeeded', p_reason, 'agent', v_uid);

  return jsonb_build_object(
    'person', v_person,
    'signals', coalesce(v_signals, '{}'),
    'relationships', v_rel,
    'affiliations', v_aff,
    'recent_interactions', v_int,
    'open_follow_ups', v_act,
    'upcoming_dates', v_dates,
    'facts', v_facts,
    'omitted', jsonb_build_object(
      'restricted_facts', n_facts_restricted,
      'restricted_interactions', n_int_restricted,
      'relationships', greatest(n_rel - c_rel, 0),
      'affiliations', greatest(n_aff - c_aff, 0),
      'interactions', greatest(n_int - c_int, 0),
      'follow_ups', greatest(n_act - c_act, 0),
      'upcoming_dates', greatest(n_dates - c_dates, 0),
      'facts', greatest(n_facts - c_facts, 0)),
    'bounds', jsonb_build_object(
      'text_chars', c_text, 'relationships', c_rel, 'affiliations', c_aff, 'interactions', c_int,
      'follow_ups', c_act, 'upcoming_dates', c_dates, 'upcoming_window_days', c_date_days, 'facts', c_facts),
    'generated_at', now());
end $fn$;

revoke all on function public.crm_briefing(uuid, text) from public, anon;
grant execute on function public.crm_briefing(uuid, text) to authenticated, service_role;

do $chk$
declare src text := (select prosrc from pg_proc where oid = 'public.crm_briefing(uuid,text)'::regprocedure);
begin
  if (select prosecdef from pg_proc where oid = 'public.crm_briefing(uuid,text)'::regprocedure) then
    raise exception 'A1: crm_briefing must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_briefing(uuid,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.crm_briefing(uuid,text)', 'execute') then
    raise exception 'A2: crm_briefing grants';
  end if;
  -- A3: no contact values and no restricted reads through this surface
  if src ~ 'c\.value\M' or src ~ 'include_restricted' then
    raise exception 'A3: crm_briefing must not read contact values or restricted classes';
  end if;
  -- A4: audit precedes the return
  if position('crm_audit(''agent_read''' in src) = 0
     or position('crm_audit(''agent_read''' in src) > position('return jsonb_build_object' in src) then
    raise exception 'A4: crm_briefing must audit before returning';
  end if;
end $chk$;
