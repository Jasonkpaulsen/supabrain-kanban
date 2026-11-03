-- CRM search performance at personal-CRM scale: TC-SB469-V7, TC-SB468-V6 (ADR-CRM-003 §6).
--
-- Generates, for one owner: 5,000 people, 15,000 contact points, 500 organizations,
-- 3,000 affiliations, 2,000 relationships, 20,000 interactions with a participant
-- each, 10,000 facts and 5,000 tag links; analyzes; times representative queries
-- as that signed-in user; then raises, so everything is rolled back, the temporary
-- tables included. Run as postgres.
-- Pass = the raised message starts with "CRM-PERF PASS".
-- Targets: crm_search median < 100 ms and worst < 250 ms; duplicate scan < 3,000 ms.

do $perf$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  t0 timestamptz;
  gen_ms int;
  ms numeric[] := '{}';
  qs text[];
  q text;
  e numeric;
  med numeric; worst numeric; dup_ms numeric; dup_n int; hits int;
  tfriend uuid;
  sample_name text; typo_name text; org_name text; note_word text;
  report jsonb := '{}'::jsonb;
begin
  t0 := clock_timestamp();
  select id into tfriend from public.crm_relationship_types where user_id is null and code = 'friend';

  -- people: pseudo-random two-word names, plus 50 deliberate near-duplicate pairs
  insert into public.crm_people (user_id, display_name)
  select ua, initcap(substr(md5('g' || i), 1, 7)) || ' ' || initcap(substr(md5('f' || i), 1, 9))
    from generate_series(1, 4900) i;
  insert into public.crm_people (user_id, display_name)
  select ua, x.n from (
    select initcap(substr(md5('d' || i), 1, 6)) || ' ' || initcap(substr(md5('e' || i), 1, 8)) as n from generate_series(1, 50) i
    union all
    select initcap(substr(md5('d' || i), 1, 6)) || ' ' || initcap(substr(md5('e' || i), 1, 8)) || 's' from generate_series(1, 50) i) x;

  create temporary table perf_people as
    select id, row_number() over (order by id) as rn from public.crm_people where user_id = ua;

  insert into public.crm_contact_points (user_id, person_id, kind, value)
  select ua, p.id, k.kind,
         case k.kind when 'email' then 'p' || p.rn || '@example.com'
                     when 'phone' then '+1555' || lpad(p.rn::text, 7, '0')
                     else '@handle' || p.rn end
    from perf_people p cross join (values ('email'), ('phone'), ('handle')) k(kind);

  insert into public.crm_organizations (user_id, name)
  select ua, 'Org ' || initcap(substr(md5('o' || i), 1, 8)) || ' Group' from generate_series(1, 500) i;
  create temporary table perf_orgs as
    select id, row_number() over (order by id) as rn from public.crm_organizations where user_id = ua;
  insert into public.crm_affiliations (user_id, person_id, organization_id, role_title)
  select ua, p.id, o.id, 'Member'
    from perf_people p join perf_orgs o on o.rn = 1 + (p.rn % 500)
   where p.rn <= 3000;

  insert into public.crm_person_relationships (user_id, person_id, related_person_id, relationship_type_id)
  select ua, a.id, b.id, tfriend
    from perf_people a join perf_people b on b.rn = a.rn + 1
   where a.rn <= 2000;

  insert into public.crm_interactions (user_id, interaction_type, occurred_at, title, summary)
  select ua, (array['call','meeting','email','message','meal'])[1 + i % 5], now() - (i || ' hours')::interval,
         'Catch-up ' || i, 'talked about ' || substr(md5('w' || i), 1, 6) || ' and ' || substr(md5('v' || i), 1, 6)
    from generate_series(1, 20000) i;
  insert into public.crm_interaction_participants (user_id, interaction_id, person_id)
  select ua, i.id, p.id
    from (select id, row_number() over (order by id) as rn from public.crm_interactions where user_id = ua) i
    join perf_people p on p.rn = 1 + (i.rn % 5000);

  insert into public.crm_facts (user_id, person_id, fact_type, value, sensitivity)
  select ua, p.id, 'note', 'note ' || substr(md5('n' || p.rn || '-' || s), 1, 8) || ' remembered',
         case when s = 2 and p.rn % 10 = 0 then 'sensitive' else 'normal' end
    from perf_people p cross join generate_series(1, 2) s;

  insert into public.crm_tags (user_id, name) select ua, 'tag' || lpad(i::text, 4, '0') from generate_series(1, 200) i;
  insert into public.crm_entity_tags (user_id, tag_id, person_id)
  select ua, t.id, p.id
    from perf_people p
    join (select id, row_number() over (order by name) as rn from public.crm_tags where user_id = ua) t on t.rn = 1 + (p.rn % 200);

  analyze public.crm_people;  analyze public.crm_contact_points;  analyze public.crm_organizations;
  analyze public.crm_affiliations;  analyze public.crm_person_relationships;  analyze public.crm_interactions;
  analyze public.crm_interaction_participants;  analyze public.crm_facts;  analyze public.crm_tags;  analyze public.crm_entity_tags;
  gen_ms := extract(epoch from clock_timestamp() - t0) * 1000;

  select display_name into sample_name from public.crm_people p join perf_people pp on pp.id = p.id where pp.rn = 2500;
  select display_name into typo_name from public.crm_people p join perf_people pp on pp.id = p.id where pp.rn = 1234;
  typo_name := left(typo_name, 3) || substr(typo_name, 5);   -- remove one letter (a typo)
  select name into org_name from public.crm_organizations o join perf_orgs po on po.id = o.id where po.rn = 250;
  select split_part(value, ' ', 2) into note_word from public.crm_facts f join perf_people pp on pp.id = f.person_id
   where pp.rn = 3333 and f.sensitivity = 'normal' limit 1;

  qs := array[sample_name, typo_name, 'p2600@example.com', 'p26', '+1 (555) 000-2700',
              split_part(org_name, ' ', 2), 'friend', 'tag0042', note_word, 'remembered'];

  -- as the signed-in owner
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform count(*) from public.crm_search('warmup');   -- plan caches, first-call overhead
  foreach q in array qs loop
    t0 := clock_timestamp();
    select count(*) into hits from public.crm_search(q);
    e := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
    ms := ms || e;
    report := report || jsonb_build_object(q, jsonb_build_object('ms', e, 'rows', hits));
  end loop;
  t0 := clock_timestamp();
  select count(*) into dup_n from public.crm_duplicate_candidates(1000);
  dup_ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);

  select percentile_cont(0.5) within group (order by v), max(v) into med, worst from unnest(ms) v;
  reset role;

  raise exception 'CRM-PERF % : search median % ms, worst % ms (targets 100 / 250); duplicate scan % ms over 5,000 people, % candidates (target 3000); data generation % ms; per query %',
    case when med < 100 and worst < 250 and dup_ms < 3000 then 'PASS' else 'FAIL' end,
    med, worst, dup_ms, dup_n, gen_ms, report::text;
end $perf$;
