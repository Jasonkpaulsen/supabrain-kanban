-- SB-469: normalized, indexed CRM search. ADR-CRM-003 §2–§3.
--
-- One function, crm_search(query), looks across names, contact values,
-- organizations, relationship types, tags and notes, and says what matched.
-- Notes use full-text search over normal and private rows only: restricted
-- classes are never searchable (agents reach them only through the audited
-- *_for_agent functions).

-- ---------------------------------------------------------------- pg_trgm
-- Installed into `extensions`, like every extension here. Supabase creates
-- extension functions as supabase_admin with EXECUTE to PUBLIC, so the SB-488
-- default (which applies to objects the postgres role creates) does not reach
-- them, and postgres cannot revoke a grant supabase_admin made. That is
-- acceptable: pg_trgm's functions are pure string computations that read no
-- table, exactly like fuzzystrmatch (CLSRM-40). What matters is asserted below:
-- authenticated can call them, and crm_search itself is not callable by anon.
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------- normalized names
-- lowercase, trimmed, internal whitespace collapsed. Accent folding is a recorded
-- follow-up (unaccent is not immutable, so it cannot back a generated column).
alter table public.crm_people
  add column name_normalized text generated always as (lower(regexp_replace(btrim(display_name), '\s+', ' ', 'g'))) stored;
alter table public.crm_organizations
  add column name_normalized text generated always as (lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))) stored;

create index crm_people_name_trgm on public.crm_people using gin (name_normalized extensions.gin_trgm_ops);
create index crm_organizations_name_trgm on public.crm_organizations using gin (name_normalized extensions.gin_trgm_ops);
-- "starts with" lookups on emails, handles and urls
create index crm_contact_points_prefix on public.crm_contact_points (user_id, value_normalized text_pattern_ops);
-- notes: full text, normal and private only (the search boundary)
create index crm_facts_fts on public.crm_facts using gin (to_tsvector('simple'::regconfig, value))
  where not archived and sensitivity in ('normal','private');
create index crm_interactions_fts on public.crm_interactions
  using gin (to_tsvector('simple'::regconfig, coalesce(title, '') || ' ' || coalesce(summary, '')))
  where not archived and sensitivity in ('normal','private');

-- ---------------------------------------------------------------- crm_search
-- SECURITY INVOKER, and it filters on user_id = auth.uid() explicitly: RLS alone
-- would let a service-role caller (which bypasses RLS) search every user's data.
-- With no user session it returns nothing.
create function public.crm_search(p_query text, p_max_results integer default 25)
returns table (person_id uuid, display_name text, matched_on text, match_detail text, rank real)
language plpgsql stable security invoker
set search_path = '' set pg_trgm.similarity_threshold = '0.3' as $fn$
declare
  v_uid uuid := auth.uid();
  q     text := btrim(coalesce(p_query, ''));
  qn    text;
  ql    text;     -- qn with LIKE metacharacters escaped
  qd    text;     -- digits and + only, for phones
  qc    text;     -- as a relationship-type code
  tsq   tsquery;
  lim   int := least(greatest(coalesce(p_max_results, 25), 1), 200);
begin
  if v_uid is null or char_length(q) < 2 then
    return;
  end if;
  qn  := lower(regexp_replace(q, '\s+', ' ', 'g'));
  ql  := replace(replace(replace(qn, '\', '\\'), '%', '\%'), '_', '\_');
  qd  := regexp_replace(q, '[^0-9+]', '', 'g');
  qc  := replace(qn, ' ', '_');
  tsq := websearch_to_tsquery('simple', q);

  return query
  with hits as (
    -- name: trigram similarity, or contains
    select p.id as pid, 'name'::text as m, p.display_name as det,
           greatest(extensions.similarity(p.name_normalized, qn),
                    case when p.name_normalized like '%' || ql || '%' then 0.5 else 0 end)::real as rk
      from public.crm_people p
     where p.user_id = v_uid and not p.archived
       and (p.name_normalized operator(extensions.%) qn or p.name_normalized like '%' || ql || '%')
    union all
    -- contact values: exact normalized value, or a prefix of 3+ characters
    select c.person_id, c.kind, c.value,
           (case when c.value_normalized = case when c.kind = 'phone' then qd else qn end then 1.0 else 0.8 end)::real
      from public.crm_contact_points c
     where c.user_id = v_uid and not c.archived
       and (   (c.kind = 'phone' and char_length(qd) >= 7 and c.value_normalized = qd)
            or (c.kind <> 'phone' and (c.value_normalized = qn
                                       or (char_length(qn) >= 3 and c.value_normalized like ql || '%'))))
    union all
    -- organization: people affiliated now or in the past
    select a.person_id, 'organization', o.name || coalesce(' (' || a.role_title || ')', ''),
           (greatest(extensions.similarity(o.name_normalized, qn),
                     case when o.name_normalized like '%' || ql || '%' then 0.5 else 0 end) * 0.9)::real
      from public.crm_organizations o
      join public.crm_affiliations a on a.organization_id = o.id and not a.archived
     where o.user_id = v_uid and not o.archived
       and (o.name_normalized operator(extensions.%) qn or o.name_normalized like '%' || ql || '%')
    union all
    -- relationship, label side: "parent" finds the parent; symmetric types both sides
    select r.person_id, 'relationship', t.label || ' of ' || other.display_name, 0.7::real
      from public.crm_person_relationships r
      join public.crm_relationship_types t on t.id = r.relationship_type_id
      join public.crm_people other on other.id = r.related_person_id
     where r.user_id = v_uid and not r.archived and (lower(t.label) = qn or t.code = qc)
    union all
    -- relationship, inverse side: "child" finds the child; symmetric types the other side
    select r.related_person_id, 'relationship', coalesce(t.inverse_label, t.label) || ' of ' || other.display_name, 0.7::real
      from public.crm_person_relationships r
      join public.crm_relationship_types t on t.id = r.relationship_type_id
      join public.crm_people other on other.id = r.person_id
     where r.user_id = v_uid and not r.archived
       and ((t.is_symmetric and (lower(t.label) = qn or t.code = qc)) or lower(t.inverse_label) = qn)
    union all
    -- tag: exact or prefix
    select et.person_id, 'tag', tg.name, (case when lower(tg.name) = qn then 0.7 else 0.6 end)::real
      from public.crm_tags tg
      join public.crm_entity_tags et on et.tag_id = tg.id and et.person_id is not null and not et.archived
     where tg.user_id = v_uid and not tg.archived
       and (lower(tg.name) = qn or lower(tg.name) like ql || '%')
    union all
    -- notes: facts, normal and private only
    select f.person_id, 'note', left(f.value, 120),
           (ts_rank(to_tsvector('simple'::regconfig, f.value), tsq) * 0.6)::real
      from public.crm_facts f
     where f.user_id = v_uid and not f.archived and f.sensitivity in ('normal','private')
       and to_tsvector('simple'::regconfig, f.value) @@ tsq
    union all
    -- notes: interaction titles and summaries, normal and private only
    select ip.person_id, 'note', left(coalesce(i.title, '') || ' ' || coalesce(i.summary, ''), 120),
           (ts_rank(to_tsvector('simple'::regconfig, coalesce(i.title, '') || ' ' || coalesce(i.summary, '')), tsq) * 0.6)::real
      from public.crm_interactions i
      join public.crm_interaction_participants ip on ip.interaction_id = i.id and ip.person_id is not null and not ip.archived
     where i.user_id = v_uid and not i.archived and i.sensitivity in ('normal','private')
       and to_tsvector('simple'::regconfig, coalesce(i.title, '') || ' ' || coalesce(i.summary, '')) @@ tsq
  ),
  best as (
    select distinct on (h.pid) h.pid, h.m, h.det, h.rk
      from hits h
     order by h.pid, h.rk desc, h.m
  )
  select p.id, p.display_name, b.m, b.det, b.rk
    from best b
    join public.crm_people p on p.id = b.pid and not p.archived
   order by b.rk desc, p.display_name
   limit lim;
end $fn$;

revoke all on function public.crm_search(text, integer) from public, anon;
grant execute on function public.crm_search(text, integer) to authenticated;

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  if not has_function_privilege('authenticated', 'extensions.similarity(text,text)', 'execute')
     or not has_function_privilege('authenticated', 'extensions.similarity_op(text,text)', 'execute') then
    raise exception 'A1: authenticated cannot run pg_trgm, so crm_search would fail for every user';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.crm_search(text,integer)'::regprocedure) then
    raise exception 'A2: crm_search must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.crm_search(text,integer)', 'execute') then
    raise exception 'A3: anon can call crm_search';
  end if;
  perform public.crm_assert_owned_table('public.crm_people');
  perform public.crm_assert_owned_table('public.crm_organizations');
end $chk$;;
