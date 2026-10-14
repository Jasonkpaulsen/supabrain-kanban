-- Handoff-gap detector suite: TC-SB558-1..6 (SB-558; ADR-FLOW-005 D9, SB-376, SB-405).
--
-- Run as postgres. One transaction that always ends by raising, so nothing survives.
-- The 14-day window moves daily, so pinned codes are asserted only when they are in the window
-- and the evidence reports how many were present; no totals are asserted.
-- Pass = the raised message starts with "HANDOFF_GAP_DETECTOR PASS". The message carries only
-- counts, booleans, ticket codes and sqlstates, never titles or free text.

do $suite$
declare
  r jsonb := '{}'::jsonb;
  n int; m int; k int; j int; fails int; st text; msg text;
  crm  constant text[] := array['SB-453','SB-456','SB-458','SB-463','SB-464','SB-467','SB-469'];
  pinned constant text[] := array['SB-453','SB-456','SB-458','SB-463','SB-464','SB-467','SB-469','SB-503','SB-540'];
  nolink constant text[] := array['SB-453','SB-458','SB-469','SB-527','SB-559'];
  haslink constant text[] := array['SB-529','SB-595'];
begin
  -- ------------------------------------------------ TC-SB558-1: one signature, short calls resolve, retired closed
  begin
    select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname = 'detect_handoff_gaps';
    st := 'ok'; begin perform count(*) from public.detect_handoff_gaps('System Architect', 14); exception when others then st := sqlstate; end;
    msg := 'ok'; begin perform count(*) from public.detect_handoff_gaps(); exception when others then msg := sqlstate; end;
    select count(*) into m from pg_proc p join pg_namespace s on s.oid = p.pronamespace
     where s.nspname = 'public' and p.proname in ('detect_handoff_gaps_retired_sb558_v1','detect_handoff_gaps_retired_sb558_v2')
       and not has_function_privilege('anon', p.oid, 'execute')
       and not has_function_privilege('authenticated', p.oid, 'execute');
    r := r || jsonb_build_object('TC-SB558-1', case when n = 1 and st = 'ok' and msg = 'ok' and m = 2 then 'pass'
           else format('FAIL: signatures %s, two-arg call %s, no-arg call %s, retired closed %s of 2', n, st, msg, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB558-1', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB558-2: CRM cluster is reviewed_only, developed by Platform Engineer
  begin
    select count(*),
           count(*) filter (where g.developed_by = 'Supabase Platform Engineer' and g.finding_type = 'reviewed_only')
      into n, m
      from public.detect_handoff_gaps('System Architect', 14, false) g
     where g.ticket_code = any (crm);
    r := r || jsonb_build_object('TC-SB558-2', case when n = m then 'pass'
           else format('FAIL: %s of %s present CRM codes are reviewed_only by Platform Engineer', m, n) end);
    r := r || jsonb_build_object('TC-SB558-2.evidence', format('%s of 7 CRM codes in window; %s reviewed_only by Platform Engineer', n, m));
  exception when others then
    r := r || jsonb_build_object('TC-SB558-2', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB558-3: no pinned code is a gap; default call is a design subset
  begin
    select count(*), count(*) filter (where g.finding_type = 'handoff_gap') into n, m
      from public.detect_handoff_gaps('System Architect', 14, false) g
     where g.ticket_code = any (pinned);
    -- default rows not in the full call, or not design work
    select count(*) into k
      from public.detect_handoff_gaps() d
     where not exists (select 1 from public.detect_handoff_gaps('System Architect', 14, false) f where f.ticket_code = d.ticket_code)
        or not (d.ticket_type = 'spike'
                or d.action_category in ('architecture_change','technical_approach_selection','workflow_design','project_plan'));
    -- each finding_type has exactly one verdict and no row lacks one
    select count(*) into j from (
      select g.finding_type from public.detect_handoff_gaps('System Architect', 14, false) g
       group by g.finding_type having count(distinct g.verdict) <> 1 or count(g.verdict) <> count(*)) x;
    r := r || jsonb_build_object('TC-SB558-3', case when m = 0 and k = 0 and j = 0 then 'pass'
           else format('FAIL: pinned handoff_gap %s of %s, default rows outside design subset %s, types with bad verdicts %s', m, n, k, j) end);
    r := r || jsonb_build_object('TC-SB558-3.evidence', format('%s of 9 pinned codes in window; handoff_gap %s', n, m));
  exception when others then
    r := r || jsonb_build_object('TC-SB558-3', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB558-4: only blocks / blocked_by count as a handoff link
  begin
    select count(*), count(*) filter (where not g.has_downstream_link) into n, m
      from public.detect_handoff_gaps('System Architect', 14, false) g where g.ticket_code = any (nolink);
    select count(*), count(*) filter (where g.has_downstream_link) into k, j
      from public.detect_handoff_gaps('System Architect', 14, false) g where g.ticket_code = any (haslink);
    r := r || jsonb_build_object('TC-SB558-4', case when n = m and k = j then 'pass'
           else format('FAIL: relates_to/duplicates-only false %s of %s; blocks true %s of %s', m, n, j, k) end);
    r := r || jsonb_build_object('TC-SB558-4.evidence', format('no-link codes present %s (false %s); blocks codes present %s (true %s)', n, m, k, j));
  exception when others then
    r := r || jsonb_build_object('TC-SB558-4', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB558-5: classify matrix, first match wins
  begin
    select count(*), count(*) filter (where public.classify_handoff_finding(v.dev, v.up, v.dl, v.mk, v.qa, v.des) is not distinct from v.expected)
      into n, m
      from (values
        ('Supabase Platform Engineer', 'System Architect', true,  true,  'tested',   true,  'reviewed_only'),
        ('System Architect',           'System Architect', true,  true,  'tested',   true,  'linked'),
        ('System Architect',           'System Architect', false, true,  'tested',   true,  'legacy_meta_backfill'),
        ('System Architect',           'System Architect', false, false, 'tested',   true,  'design_complete'),
        ('System Architect',           'System Architect', false, false, 'tested',   false, 'role_boundary'),
        ('System Architect',           'System Architect', false, false, 'exempt',   true,  'shipped_exempt'),
        ('System Architect',           'System Architect', false, false, 'untested', true,  'handoff_gap'),
        ('System Architect',           'System Architect', false, false, null,       false, 'self_contained'),
        -- edges: a null developer is distinct; null booleans are false; exempt non-design is still shipped
        (null,                         'System Architect', false, false, null,       true,  'reviewed_only'),
        ('System Architect',           'System Architect', null,  null,  null,       null,  'self_contained'),
        ('System Architect',           'System Architect', false, false, 'exempt',   false, 'shipped_exempt'),
        ('System Architect',           'System Architect', false, false, null,       true,  'handoff_gap')
      ) v(dev, up, dl, mk, qa, des, expected);
    r := r || jsonb_build_object('TC-SB558-5', case when n = 12 and m = 12 then 'pass'
           else format('FAIL: %s of %s matrix cases', m, n) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB558-5', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB558-6: posture and result shape
  begin
    select count(*) into n from pg_proc p
     where p.oid = 'public.detect_handoff_gaps(text,integer,boolean)'::regprocedure
       and p.prolang = (select oid from pg_language where lanname = 'sql')
       and p.provolatile = 's' and not p.prosecdef
       and p.proconfig @> array['search_path=public']
       and not has_function_privilege('anon', p.oid, 'execute')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and has_function_privilege('service_role', p.oid, 'execute')
       and obj_description(p.oid, 'pg_proc') like 'Escalate only finding_type = handoff_gap;%'
       and p.proargnames[4:15] = array['ticket_code','title','ticket_type','action_category','completed_at','assignee',
                                       'developed_by','qa_status','has_downstream_link','has_meta_key','finding_type','verdict']
       and cardinality(p.proargnames) = 15;
    select count(*) into m from pg_proc p
     where p.oid = 'public.classify_handoff_finding(text,text,boolean,boolean,text,boolean)'::regprocedure
       and p.provolatile = 'i' and not p.prosecdef
       and p.prorettype = 'text'::regtype
       and not has_function_privilege('anon', p.oid, 'execute');
    r := r || jsonb_build_object('TC-SB558-6', case when n = 1 and m = 1 then 'pass'
           else format('FAIL: detector posture %s, classifier posture %s', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB558-6', 'FAIL: error ' || sqlstate);
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'HANDOFF_GAP_DETECTOR PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'HANDOFF_GAP_DETECTOR FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
