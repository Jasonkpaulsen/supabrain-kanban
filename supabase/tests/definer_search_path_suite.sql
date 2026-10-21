-- SECURITY DEFINER search_path suite: TC-SB622-01, TC-SB622-02 (SB-622).
--
-- Run as postgres. One transaction that always ends by raising, so the temp shadow tables
-- and the session search_path it sets do not survive. Pass = the raised message starts with
-- "DEFINER_SEARCH_PATH PASS". The message carries only counts and names, never row values.
--
-- TC-SB622-01: escalate_overdue_reviews runs as its owner, so a caller who can put objects
-- ahead of public on the search_path must not be able to substitute its inputs. Two layers:
-- .config pins search_path = '' (this is what stops a substitution of anything unqualified,
-- operators and functions included), and .qualified/.sentinel check the body names its
-- relations by schema. The sentinel shadows vw_review_sla and work_items in pg_temp, proves
-- the shadow WOULD win for an unqualified reference, then checks the function ignores it and
-- returns exactly the breached rows of public.vw_review_sla. The sentinel alone would pass on
-- an unpinned but qualified body; .config and TC-SB622-02 are what catch a lost pin.
-- TC-SB622-02: class guard. No SECURITY DEFINER function in public (extension members
-- aside) may lack a pinned search_path.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  fn constant regprocedure := 'public.escalate_overdue_reviews(uuid)'::regprocedure;
  r jsonb := '{}'::jsonb;
  n int; m int; fails int; cfg text[]; src text; names text;
begin
  -- TC-SB622-01 posture
  select proconfig, prosrc into cfg, src from pg_proc where oid = fn;
  r := r || jsonb_build_object('TC-SB622-01.config',
         case when cfg = array['search_path=""'] then 'pass' else 'FAIL: proconfig ' || coalesce(cfg::text, 'null') end);
  r := r || jsonb_build_object('TC-SB622-01.qualified',
         case when src like '%public.vw_review_sla%' and src like '%public.work_items%' then 'pass'
              else 'FAIL: body does not schema-qualify vw_review_sla and work_items' end);
  r := r || jsonb_build_object('TC-SB622-01.grants',
         case when not has_function_privilege('anon', fn, 'execute')
               and not has_function_privilege('authenticated', fn, 'execute')
               and has_function_privilege('service_role', fn, 'execute') then 'pass'
              else 'FAIL: execute grants changed' end);

  -- TC-SB622-01 shadow
  create temp table vw_review_sla (id uuid, ticket_code text, title text, hours_in_review numeric,
                                   sla_status text, assignee text, project_name text, sla_breached boolean);
  create temp table work_items (id uuid, user_id uuid);
  insert into pg_temp.vw_review_sla values ('00000000-0000-4000-8000-000000000622', 'ZZS-622', 'shadow', 9999,
                                            'breached', null, 'shadow', true);
  insert into pg_temp.work_items values ('00000000-0000-4000-8000-000000000622', ub);
  perform set_config('search_path', 'pg_temp, public', true);

  execute 'select count(*) from vw_review_sla where ticket_code = ''ZZS-622''' into n;
  r := r || jsonb_build_object('TC-SB622-01.control',
         case when n = 1 then 'pass' else 'FAIL: shadow not reachable unqualified (' || n || ')' end);

  select count(*) into n from public.escalate_overdue_reviews(null) e where e.ticket_code = 'ZZS-622';
  select count(*) into m from public.escalate_overdue_reviews(ub) e where e.ticket_code = 'ZZS-622';
  r := r || jsonb_build_object('TC-SB622-01.sentinel',
         case when n + m = 0 then 'pass' else 'FAIL: shadow row returned (' || n || '/' || m || ')' end);

  select count(*) into n from (
    (select e.ticket_code, e.hours_in_review from public.escalate_overdue_reviews(null) e
     except all
     select v.ticket_code, v.hours_in_review from public.vw_review_sla v where v.sla_breached)
    union all
    (select v.ticket_code, v.hours_in_review from public.vw_review_sla v where v.sla_breached
     except all
     select e.ticket_code, e.hours_in_review from public.escalate_overdue_reviews(null) e)) d;
  select count(*) into m from public.vw_review_sla v where v.sla_breached;
  r := r || jsonb_build_object('TC-SB622-01.rows',
         case when n = 0 then 'pass' else 'FAIL: ' || n || ' rows differ from public.vw_review_sla' end,
         'TC-SB622-01.evidence', m || ' breached rows compared');

  -- TC-SB622-02 class guard
  select count(*), coalesce(string_agg(p.oid::regprocedure::text, ', '), '') into n, names
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c where c like 'search_path=%')
     and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e');
  r := r || jsonb_build_object('TC-SB622-02',
         case when n = 0 then 'pass' else 'FAIL: ' || n || ' unpinned: ' || names end);

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'DEFINER_SEARCH_PATH PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'DEFINER_SEARCH_PATH FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
