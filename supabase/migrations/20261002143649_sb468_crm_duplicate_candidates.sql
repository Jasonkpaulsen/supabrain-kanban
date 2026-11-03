-- SB-468: duplicate candidates with explainable reasons, and dismissals.
-- ADR-CRM-003 §4.
--
-- Candidates are computed on read by a STABLE function, which Postgres refuses to
-- let write anything, so detection cannot change data. Nothing merges people
-- automatically; merging is SB-467's explicit, reasoned call.
--
-- What makes a pair a candidate:
--   strong   : the same normalized email, phone or handle on both people
--   possible : name similarity >= 0.6 with context (same name, same birthday or
--              a shared organization), or name similarity >= 0.8 on its own
-- Context alone never does: a shared employer would flag every colleague.
--
-- No function here pins pg_trgm.similarity_threshold. Setting it in a function's
-- SET clause is refused (permission denied to set parameter) once the module is
-- loaded, so the % operator runs at its default 0.3, which is index-assisted, and
-- the 0.6 floor is an explicit similarity() filter. crm_search (SB-469) carried
-- the same clause; it is redefined below without it, so search cannot start
-- failing the day the module happens to be loaded first. Search keeps the 0.3
-- default it was pinned to.

-- ---------------------------------------------------------------- dismissals
create table public.crm_duplicate_dismissals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  person_a    uuid not null,
  person_b    uuid not null,
  reason_code text not null default 'not_same_person' check (reason_code ~ '^[a-z0-9_]{3,64}$'),
  archived    boolean not null default false,
  archived_at timestamptz,
  meta        jsonb not null default '{}'::jsonb check (jsonb_typeof(meta) = 'object'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- canonical order, so a pair has exactly one spelling
  constraint crm_duplicate_dismissals_ordered check (person_a < person_b),
  constraint crm_duplicate_dismissals_a_fk foreign key (person_a, user_id)
    references public.crm_people (id, user_id) on delete cascade,
  constraint crm_duplicate_dismissals_b_fk foreign key (person_b, user_id)
    references public.crm_people (id, user_id) on delete cascade
);
comment on table public.crm_duplicate_dismissals is
  'SB-468 / ADR-CRM-003. A pair the owner has said is not the same person. Archive the row to un-dismiss.';

-- one live dismissal per pair
create unique index crm_duplicate_dismissals_pair on public.crm_duplicate_dismissals (person_a, person_b) where not archived;
create index crm_duplicate_dismissals_user on public.crm_duplicate_dismissals (user_id);
create index crm_duplicate_dismissals_a on public.crm_duplicate_dismissals (person_a, user_id);
create index crm_duplicate_dismissals_b on public.crm_duplicate_dismissals (person_b, user_id);

select public.crm_secure_owned_table('public.crm_duplicate_dismissals');

-- Dismiss a pair, given in either order.
create function public.crm_dismiss_duplicate(
  p_person_one uuid,
  p_person_two uuid,
  p_reason     text default 'not_same_person'
) returns uuid
language sql security invoker set search_path = '' as $fn$
  insert into public.crm_duplicate_dismissals (person_a, person_b, reason_code)
  values (least(p_person_one, p_person_two), greatest(p_person_one, p_person_two), coalesce(p_reason, 'not_same_person'))
  returning id;
$fn$;

revoke all on function public.crm_dismiss_duplicate(uuid, uuid, text) from public, anon;
grant execute on function public.crm_dismiss_duplicate(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------------- candidates
-- STABLE (read-only, enforced by Postgres) and SECURITY INVOKER, filtered on
-- user_id = auth.uid() explicitly, as crm_search is: no user session, no rows.
create function public.crm_duplicate_candidates(p_max_results integer default 100)
returns table (person_a uuid, person_b uuid, name_a text, name_b text, strength text, reasons text[])
language plpgsql stable security invoker
set search_path = '' as $fn$
declare
  v_uid uuid := auth.uid();
  lim   int := least(greatest(coalesce(p_max_results, 100), 1), 1000);
begin
  if v_uid is null then
    return;
  end if;

  return query
  with shared_ids as (
    select least(c1.person_id, c2.person_id) as a, greatest(c1.person_id, c2.person_id) as b,
           'same ' || c1.kind || ' ' || c1.value_normalized as reason, true as strong
      from public.crm_contact_points c1
      join public.crm_contact_points c2
        on c2.user_id = c1.user_id and c2.kind = c1.kind
       and c2.value_normalized = c1.value_normalized and c2.person_id > c1.person_id
     where c1.user_id = v_uid and c1.kind in ('email','phone','handle')
       and not c1.archived and not c2.archived
  ),
  similar_names as (
    select p1.id as a, p2.id as b,
           extensions.similarity(p1.name_normalized, p2.name_normalized) as sim,
           p1.name_normalized = p2.name_normalized as same_name
      from public.crm_people p1
      join public.crm_people p2
        on p2.user_id = p1.user_id and p2.id > p1.id
       and p1.name_normalized operator(extensions.%) p2.name_normalized
     where p1.user_id = v_uid and not p1.archived and not p2.archived
       and extensions.similarity(p1.name_normalized, p2.name_normalized) >= 0.6
  ),
  with_context as (
    select n.a, n.b, n.sim, n.same_name,
           exists (select 1
                     from public.crm_important_dates d1
                     join public.crm_important_dates d2
                       on d2.person_id = n.b and d2.kind = 'birthday' and not d2.archived
                      and d2.month = d1.month and d2.day = d1.day
                      and (d1.year is null or d2.year is null or d1.year = d2.year)
                    where d1.person_id = n.a and d1.kind = 'birthday' and not d1.archived) as same_birthday,
           (select min(o.name)
              from public.crm_affiliations a1
              join public.crm_affiliations a2 on a2.organization_id = a1.organization_id
                                             and a2.person_id = n.b and not a2.archived
              join public.crm_organizations o on o.id = a1.organization_id
             where a1.person_id = n.a and not a1.archived) as shared_org
      from similar_names n
  ),
  name_reasons as (
    select w.a, w.b, x.reason, false as strong
      from with_context w
     cross join lateral unnest(array_remove(array[
             format('similar names (%s)', round(w.sim::numeric, 2)),
             case when w.same_name then 'same name' end,
             case when w.same_birthday then 'same birthday' end,
             case when w.shared_org is not null then 'both at ' || w.shared_org end
           ], null)) as x(reason)
     where w.same_name or w.same_birthday or w.shared_org is not null or w.sim >= 0.8
  ),
  all_reasons as (
    select * from shared_ids
    union all
    select * from name_reasons
  )
  select r.a, r.b, pa.display_name, pb.display_name,
         case when bool_or(r.strong) then 'strong' else 'possible' end,
         array_agg(distinct r.reason order by r.reason)
    from all_reasons r
    join public.crm_people pa on pa.id = r.a and not pa.archived
    join public.crm_people pb on pb.id = r.b and not pb.archived
   where not exists (select 1 from public.crm_duplicate_dismissals d
                      where d.person_a = r.a and d.person_b = r.b and not d.archived)
   group by r.a, r.b, pa.display_name, pb.display_name
   order by bool_or(r.strong) desc, count(*) desc, pa.display_name, pb.display_name
   limit lim;
end $fn$;

revoke all on function public.crm_duplicate_candidates(integer) from public, anon;
grant execute on function public.crm_duplicate_candidates(integer) to authenticated;

-- ---------------------------------------------------------------- crm_search: drop the pinned threshold
-- ALTER FUNCTION ... RESET is refused for the same reason, so redefine it with an
-- identical body and no SET for the parameter. Same signature: grants carry over.
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

-- ---------------------------------------------------------------- assertions
do $chk$
begin
  perform public.crm_assert_owned_table('public.crm_duplicate_dismissals');
  if (select provolatile from pg_proc where oid = 'public.crm_duplicate_candidates(integer)'::regprocedure) <> 's' then
    raise exception 'A1: crm_duplicate_candidates must be STABLE, so it cannot write';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.crm_duplicate_candidates(integer)'::regprocedure)
     or (select prosecdef from pg_proc where oid = 'public.crm_dismiss_duplicate(uuid,uuid,text)'::regprocedure) then
    raise exception 'A2: duplicate functions must be SECURITY INVOKER';
  end if;
  if exists (select 1 from pg_proc where proname in ('crm_search','crm_duplicate_candidates')
              and array_to_string(proconfig, ',') like '%pg_trgm%') then
    raise exception 'A4: a CRM function still pins a pg_trgm setting';
  end if;
  if has_function_privilege('anon', 'public.crm_duplicate_candidates(integer)', 'execute')
     or has_function_privilege('anon', 'public.crm_dismiss_duplicate(uuid,uuid,text)', 'execute') then
    raise exception 'A3: anon can call a duplicate function';
  end if;
end $chk$;;
