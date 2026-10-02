-- SB-468 / SB-469 follow-up, found by the ADR-CRM-003 §6 performance check
-- (supabase/tests/crm_search_perf.sql) before either ticket closed.
--
-- 1. Duplicate scan. The name pass joined every person against every other via the
--    trigram % operator: 2.0 s at 1,000 people, growing far faster than linear, so
--    the 3 s target at 5,000 was out of reach. Names are now compared only within
--    blocks: people who share a name word, or that word's double-metaphone code
--    (fuzzystrmatch, already installed). Every pair the rules care about shares
--    one: Katherine/Catherine *Holloway*, Jonathan/Jonathon *Marlowe*, Jon/John
--    (both JN). A word shared by more than 200 people (a very common first name)
--    is not used as a block on its own; such people still pair through their
--    other words. Scoring and reasons are unchanged.
--
-- 2. Search latency. With GIN fastupdate (the default), new rows wait in a pending
--    list that every search scans until autovacuum flushes it, and the planner
--    then prefers a sequential scan: the interaction-notes branch took 28 ms at
--    4,000 rows. A personal CRM is write-light and read-heavy, so the four search
--    indexes insert directly instead.

alter index public.crm_people_name_trgm        set (fastupdate = off);
alter index public.crm_organizations_name_trgm set (fastupdate = off);
alter index public.crm_facts_fts               set (fastupdate = off);
alter index public.crm_interactions_fts        set (fastupdate = off);
select gin_clean_pending_list(i::regclass)
  from unnest(array['public.crm_people_name_trgm','public.crm_organizations_name_trgm',
                    'public.crm_facts_fts','public.crm_interactions_fts']) i;

create or replace function public.crm_duplicate_candidates(p_max_results integer default 100)
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
  -- blocking keys: each name word, and its double-metaphone code
  name_keys as (
    select distinct p.id, k.key
      from public.crm_people p
     cross join lateral unnest(regexp_split_to_array(p.name_normalized, '[\s-]+')) as w(word)
     cross join lateral (values ('w:' || w.word),
                                ('m:' || nullif(extensions.dmetaphone(w.word), ''))) as k(key)
     where p.user_id = v_uid and not p.archived
       and char_length(w.word) >= 2 and k.key is not null
  ),
  usable_keys as (
    select nk.id, nk.key
      from (select id, key, count(*) over (partition by key) as members from name_keys) nk
     where nk.members between 2 and 200
  ),
  blocked_pairs as (
    select distinct k1.id as a, k2.id as b
      from usable_keys k1
      join usable_keys k2 on k2.key = k1.key and k2.id > k1.id
  ),
  similar_names as (
    select bp.a, bp.b,
           extensions.similarity(p1.name_normalized, p2.name_normalized) as sim,
           p1.name_normalized = p2.name_normalized as same_name
      from blocked_pairs bp
      join public.crm_people p1 on p1.id = bp.a
      join public.crm_people p2 on p2.id = bp.b
     where extensions.similarity(p1.name_normalized, p2.name_normalized) >= 0.6
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

do $chk$
begin
  if exists (select 1 from pg_class c
              where c.relname in ('crm_people_name_trgm','crm_organizations_name_trgm','crm_facts_fts','crm_interactions_fts')
                and not coalesce(c.reloptions, '{}') @> array['fastupdate=off']) then
    raise exception 'A1: a CRM search index still defers inserts (fastupdate)';
  end if;
  if (select provolatile from pg_proc where oid = 'public.crm_duplicate_candidates(integer)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.crm_duplicate_candidates(integer)'::regprocedure) then
    raise exception 'A2: crm_duplicate_candidates must stay STABLE and SECURITY INVOKER';
  end if;
  if not has_function_privilege('authenticated', 'extensions.dmetaphone(text)', 'execute') then
    raise exception 'A3: authenticated cannot run dmetaphone, so the duplicate scan would fail';
  end if;
  if has_function_privilege('anon', 'public.crm_duplicate_candidates(integer)', 'execute') then
    raise exception 'A4: anon can call crm_duplicate_candidates';
  end if;
end $chk$;;
