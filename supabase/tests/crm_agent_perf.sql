-- CRM agent intelligence performance at personal-CRM scale: TC-SB471-V8 (ADR-CRM-004 §4).
--
-- The ADR-CRM-003 §6 dataset for one owner (5,000 people, 15,000 contact points,
-- 500 organizations, 3,000 affiliations, 2,000 relationships, 20,000 interactions,
-- 10,000 facts), plus what the recommendations read: 1,000 people with a cadence,
-- 2,000 open follow-ups (half overdue), 2,000 birthdays across the year, 500
-- unconfirmed agent facts, and 50 shared-email duplicate pairs. Analyzes, times
-- crm_recommendations(50) and one crm_briefing as that signed-in user, then raises,
-- so everything is rolled back. Run as postgres.
-- Pass = the raised message starts with "CRM-AGENT-PERF PASS".
-- Targets: recommendations under 1,000 ms (median of 3); briefing under 250 ms.

do $perf$
declare
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  t0 timestamptz;
  gen_ms int;
  ms numeric[] := '{}';
  e numeric;
  med numeric; brief_ms numeric; rec_n int; kinds jsonb; target uuid;
  tfriend uuid;
begin
  t0 := clock_timestamp();
  select id into tfriend from public.crm_relationship_types where user_id is null and code = 'friend';

  insert into public.crm_people (user_id, display_name)
  select ua, initcap(substr(md5('g' || i), 1, 7)) || ' ' || initcap(substr(md5('f' || i), 1, 9))
    from generate_series(1, 5000) i;
  create temporary table perf_people as
    select id, row_number() over (order by id) as rn from public.crm_people where user_id = ua;
  update public.crm_people p set contact_cadence_days = 30, relationship_priority = 1 + (pp.rn % 5)::smallint
    from perf_people pp where pp.id = p.id and pp.rn <= 1000;

  insert into public.crm_contact_points (user_id, person_id, kind, value)
  select ua, p.id, k.kind,
         case k.kind when 'email' then 'p' || p.rn || '@example.com'
                     when 'phone' then '+1555' || lpad(p.rn::text, 7, '0')
                     else '@handle' || p.rn end
    from perf_people p cross join (values ('email'), ('phone'), ('handle')) k(kind)
   where p.rn > 50;   -- the first 50 people have no contact point at all
  -- 50 duplicate pairs: people 4901..4950 share an email with 4951..5000
  insert into public.crm_contact_points (user_id, person_id, kind, value)
  select ua, p.id, 'email', 'shared' || (case when p.rn > 4950 then p.rn - 50 else p.rn end) || '@example.com'
    from perf_people p where p.rn > 4900;

  insert into public.crm_organizations (user_id, name)
  select ua, 'Org ' || initcap(substr(md5('o' || i), 1, 8)) || ' Group' from generate_series(1, 500) i;
  create temporary table perf_orgs as
    select id, row_number() over (order by id) as rn from public.crm_organizations where user_id = ua;
  insert into public.crm_affiliations (user_id, person_id, organization_id, role_title)
  select ua, p.id, o.id, 'Member' from perf_people p join perf_orgs o on o.rn = 1 + (p.rn % 500) where p.rn <= 3000;
  insert into public.crm_person_relationships (user_id, person_id, related_person_id, relationship_type_id)
  select ua, a.id, b.id, tfriend from perf_people a join perf_people b on b.rn = a.rn + 1 where a.rn <= 2000;

  insert into public.crm_interactions (user_id, interaction_type, occurred_at, title, summary)
  select ua, (array['call','meeting','email','message','meal'])[1 + i % 5], now() - (i || ' hours')::interval,
         'Catch-up ' || i, 'talked about ' || substr(md5('w' || i), 1, 6)
    from generate_series(1, 20000) i;
  insert into public.crm_interaction_participants (user_id, interaction_id, person_id)
  select ua, i.id, p.id
    from (select id, row_number() over (order by id) as rn from public.crm_interactions where user_id = ua) i
    join perf_people p on p.rn = 1 + (i.rn % 5000);

  insert into public.crm_facts (user_id, person_id, fact_type, value)
  select ua, p.id, 'note', 'note ' || substr(md5('n' || p.rn || '-' || s), 1, 8)
    from perf_people p cross join generate_series(1, 2) s;
  insert into public.crm_facts (user_id, person_id, fact_type, value, source_type, source_ref, confidence)
  select ua, p.id, 'employer_guess', 'guess ' || p.rn, 'agent', 'perf_agent', 0.5
    from perf_people p where p.rn % 10 = 0;

  insert into public.crm_actions (user_id, title, person_id, due_at)
  select ua, 'Task ' || p.rn, p.id, now() + ((p.rn % 60) - 30 || ' days')::interval
    from perf_people p where p.rn <= 2000;

  insert into public.crm_important_dates (user_id, person_id, kind, month, day, year)
  select ua, p.id, 'birthday', extract(month from current_date + (p.rn % 365)::int)::smallint,
         extract(day from current_date + (p.rn % 365)::int)::smallint, 1970 + (p.rn % 40)
    from perf_people p where p.rn <= 2000;

  analyze public.crm_people;  analyze public.crm_contact_points;  analyze public.crm_organizations;
  analyze public.crm_affiliations;  analyze public.crm_person_relationships;  analyze public.crm_interactions;
  analyze public.crm_interaction_participants;  analyze public.crm_facts;  analyze public.crm_actions;
  analyze public.crm_important_dates;
  gen_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  select id into target from perf_people where rn = 1500;   -- has a cadence, interactions, facts, a follow-up, a birthday

  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform count(*) from public.crm_recommendations(5);   -- warm-up
  for i in 1..3 loop
    t0 := clock_timestamp();
    select count(*) into rec_n from public.crm_recommendations(50);
    e := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
    ms := ms || e;
  end loop;
  select jsonb_object_agg(k, c) into kinds
    from (select x.kind as k, count(*) as c from public.crm_recommendations(500) x group by x.kind) z;
  t0 := clock_timestamp();
  perform public.crm_briefing(target, 'perf_check');
  brief_ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
  select percentile_cont(0.5) within group (order by v) into med from unnest(ms) v;
  reset role;

  raise exception 'CRM-AGENT-PERF % : recommendations median % ms over 3 runs % (target 1000), % returned; kinds in top 500 %; briefing % ms (target 250); data generation % ms',
    case when med < 1000 and brief_ms < 250 then 'PASS' else 'FAIL' end,
    med, ms, rec_n, kinds, brief_ms, gen_ms;
end $perf$;
