-- SB-469 follow-up, found by the ADR-CRM-003 §6 performance check: crm_search took
-- about 220 ms per query at 5,000 people whatever the query (target: 100 ms median).
--
-- Cause: under row-level security Postgres will not drive an index scan from a
-- qualifier that is not leakproof (full-text @@, trigram %, LIKE), so every branch
-- is a sequential scan, and the notes branches recomputed to_tsvector() for every
-- fact and interaction on every search. Most of the time was that recomputation.
--
-- Fix, with row-level security left fully in force: store the vector as a generated
-- column, so the scan compares stored vectors instead of rebuilding them.
-- crm_search stays SECURITY INVOKER. (Running it with owner rights would let the
-- indexes drive the scan, but that moves isolation from the database's policies to
-- the function's own filters; it is not done here and is left to a human decision.)

alter table public.crm_facts
  add column search_tsv tsvector generated always as (to_tsvector('simple'::regconfig, value)) stored;
alter table public.crm_interactions
  add column search_tsv tsvector generated always as
    (to_tsvector('simple'::regconfig, coalesce(title, '') || ' ' || coalesce(summary, ''))) stored;

create or replace function public.crm_search(p_query text, p_max_results integer default 25)
returns table (person_id uuid, display_name text, matched_on text, match_detail text, rank real)
language plpgsql stable security invoker
set search_path = '' as $fn$
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
           (ts_rank(f.search_tsv, tsq) * 0.6)::real
      from public.crm_facts f
     where f.user_id = v_uid and not f.archived and f.sensitivity in ('normal','private')
       and f.search_tsv @@ tsq
    union all
    -- notes: interaction titles and summaries, normal and private only
    select ip.person_id, 'note', left(coalesce(i.title, '') || ' ' || coalesce(i.summary, ''), 120),
           (ts_rank(i.search_tsv, tsq) * 0.6)::real
      from public.crm_interactions i
      join public.crm_interaction_participants ip on ip.interaction_id = i.id and ip.person_id is not null and not ip.archived
     where i.user_id = v_uid and not i.archived and i.sensitivity in ('normal','private')
       and i.search_tsv @@ tsq
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

do $chk$
declare src text := (select prosrc from pg_proc where oid = 'public.crm_search(text,integer)'::regprocedure);
begin
  if (select prosecdef from pg_proc where oid = 'public.crm_search(text,integer)'::regprocedure) then
    raise exception 'A1: crm_search must stay SECURITY INVOKER';
  end if;
  if src like '%to_tsvector(%' then
    raise exception 'A2: crm_search still rebuilds vectors per row';
  end if;
  if has_function_privilege('anon', 'public.crm_search(text,integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.crm_search(text,integer)', 'execute') then
    raise exception 'A3: crm_search grants changed';
  end if;
  perform public.crm_assert_owned_table('public.crm_facts');
  perform public.crm_assert_owned_table('public.crm_interactions');
end $chk$;;
