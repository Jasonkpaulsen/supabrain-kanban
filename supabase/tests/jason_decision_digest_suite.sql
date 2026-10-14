-- Jason decision digest suite: TC-SB554-1..8 (SB-554; ADR-FLOW-005 D6-D7).
--
-- Run as postgres. One transaction that always ends by raising, so nothing it creates or
-- inserts survives (fixtures, probe escalations, and the enforce-mode replacement of
-- escalation_gate_mode in TC-SB554-8). Fixtures are SB-project chores owned by the owner.
-- Pass = the raised message starts with "JASON_DECISION_DIGEST PASS". The message carries only
-- counts, ticket codes, classes and sqlstates, never titles or free text.

do $suite$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  pj  constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  rb  constant text := '__sb554_rollback__';
  r jsonb := '{}'::jsonb;
  fa uuid; fb uuid; fq uuid; fc uuid; fc2 uuid; fd uuid; fe uuid; ff uuid;
  ca text; cb text; cq text; cc text; cc2 text; cd text; ce text; cf text;
  h1 uuid; h2 uuid; h3 uuid; h4 uuid; k1 text; k2 text; k3 text; k4 text;
  pa uuid; pb uuid; pc uuid; pg uuid; pm uuid; pl uuid; cpa text; cpg text;
  t text[]; m jsonb; n int; k int; fails int; st text; st2 text; msg text; v jsonb;
begin
  -- ------------------------------------------------ fixtures (subjects)
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status)
    values (pj, ub, 'qa-sb554 subject a awaiting', 'chore', 'awaiting_jason', 'medium', 'not_required')
    returning id, ticket_code into fa, ca;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, authority_level, meta)
    values (pj, ub, 'qa-sb554 subject b pending proposal', 'chore', 'backlog', 'medium', 'pending', 2,
            '{"proposal_type":"process_improvement"}')
    returning id, ticket_code into fb, cb;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
    values (pj, ub, 'qa-sb554 subject requires flag', 'chore', 'todo', 'medium', 'not_required', '{"requires_jason":"true"}')
    returning id, ticket_code into fq, cq;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status)
    values (pj, ub, 'qa-sb554 subject c blocked one hop', 'chore', 'blocked', 'medium', 'not_required')
    returning id, ticket_code into fc, cc;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status)
    values (pj, ub, 'qa-sb554 subject c2 blocked_by one hop', 'chore', 'blocked', 'medium', 'not_required')
    returning id, ticket_code into fc2, cc2;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status)
    values (pj, ub, 'qa-sb554 subject d agent', 'chore', 'todo', 'medium', 'not_required')
    returning id, ticket_code into fd, cd;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
    values (pj, ub, 'qa-sb554 subject e external wait', 'chore', 'awaiting_jason', 'critical', 'not_required',
            '{"awaiting_external":"outside party"}')
    returning id, ticket_code into fe, ce;
  insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status)
    values (pj, ub, 'qa-sb554 subject f closed', 'chore', 'done', 'medium', 'not_required')
    returning id, ticket_code into ff, cf;
  insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, fa, fc, 'blocks');
  insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, fc2, fa, 'blocked_by');

  -- ------------------------------------------------ TC-SB554-1: classifier a..d
  begin
    t := array[
      public.jason_blocker_class(array[ca]),            -- a awaiting_jason
      public.jason_blocker_class(array[cb]),            -- b pending L2 proposal
      public.jason_blocker_class(array[cq]),            -- requires_jason 'true'
      public.jason_blocker_class(array[cc]),            -- c X blocks subject, X awaiting_jason
      public.jason_blocker_class(array[cc2]),           -- c subject blocked_by X
      public.jason_blocker_class(array[cd]),            -- d agent
      public.jason_blocker_class(array[ce]),            -- outside-party wait is not a Jason decision
      public.jason_blocker_class(array['ZZQ-99999']),   -- unknown
      public.jason_blocker_class(array[cf]),            -- closed subject
      public.jason_blocker_class(array[cd, ca])];       -- any human subject wins
    k := 0;
    if public.escalation_subject_codes('{"blocker_ref":" sb-1 ","upstream_ticket":"SB-2","related_tickets":["SB-2","x","CIP-3",5],"requires_jason":["ww-4"]}')
       = array['CIP-3','SB-1','SB-2','WW-4'] then k := k + 1; end if;
    if public.escalation_subject_codes('{"related_tickets":"SB-1, SB-2","requires_jason":true}') = '{}'::text[] then k := k + 1; end if;
    if public.escalation_subject_codes(null) = '{}'::text[] then k := k + 1; end if;
    r := r || jsonb_build_object('TC-SB554-1', case
           when t = array['human_decision','human_decision','human_decision','human_decision','human_decision',
                          'agent','agent','unresolved','unresolved','human_decision'] and k = 3 then 'pass'
           else format('FAIL: classes %s, subject-code checks %s of 3', t, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-2: trigger tags probe A / probe B
  begin
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
      values (pj, ub, 'ESCALATION: qa-sb554 probe A', 'chore', 'todo', 'high', 'not_required', jsonb_build_object('blocker_ref', ca))
      returning id, ticket_code into pa, cpa;
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
      values (pj, ub, 'ESCALATION: qa-sb554 probe B', 'chore', 'todo', 'high', 'not_required', jsonb_build_object('upstream_ticket', cd))
      returning id into pb;
    select array[a.meta->>'blocker_class', a.meta->>'digest_routed', a.meta->>'classified_by',
                 b.meta->>'blocker_class', b.meta->>'digest_routed', b.meta->>'classified_by']
      into t from public.work_items a, public.work_items b where a.id = pa and b.id = pb;
    r := r || jsonb_build_object('TC-SB554-2', case
           when t = array['human_decision','true','SB-554','agent','false','SB-554'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-3: L3 + flagged probe C
  begin
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, authority_level, meta)
      values (pj, ub, 'ESCALATION: qa-sb554 probe C', 'chore', 'backlog', 'high', 'not_required', 3,
              jsonb_build_object('upstream_ticket', cd, 'flagged_for_jason', 'true'))
      returning id into pc;
    select array[meta->>'blocker_class', meta->>'digest_routed'] into t from public.work_items where id = pc;
    r := r || jsonb_build_object('TC-SB554-3', case when t = array['human_decision','true'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-4: plain insert untouched; malformed meta inserts
  begin
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
      values (pj, ub, 'qa-sb554 plain chore', 'chore', 'todo', 'low', 'not_required', jsonb_build_object('blocker_ref', ca))
      returning id into pl;
    st := 'ok';
    begin
      insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
        values (pj, ub, 'ESCALATION: qa-sb554 malformed', 'chore', 'todo', 'low', 'not_required',
                '{"related_tickets":"SB-1, SB-2","requires_jason":{"x":1}}')
        returning id into pm;
    exception when others then st := sqlstate;
    end;
    select array[(meta ? 'blocker_class')::text, (meta ? 'classified_by')::text] into t from public.work_items where id = pl;
    t := t || array[st, coalesce((select meta->>'blocker_class' from public.work_items where id = pm), 'none')];
    r := r || jsonb_build_object('TC-SB554-4', case when t = array['false','false','ok','unresolved'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-5: digest once per item, escalations folded
  begin
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
      values (pj, ub, 'ESCALATION: qa-sb554 probe G awaiting', 'chore', 'awaiting_jason', 'critical', 'not_required',
              jsonb_build_object('blocker_ref', ca))
      returning id, ticket_code into pg, cpg;
    msg := '';
    select count(*) - count(distinct ticket_code) into n from public.vw_jason_decision_digest;
    if n <> 0 then msg := msg || format('[duplicates %s] ', n); end if;
    select count(*) into n
      from public.vw_jason_decision_digest d join public.work_items w on w.ticket_code = d.ticket_code
     where w.title ilike 'ESCALATION%' and (w.meta->>'blocker_class' = 'human_decision' or coalesce(w.authority_level, 0) >= 3);
    if n <> 0 then msg := msg || format('[folded rows listed %s] ', n); end if;
    select escalations_attached into t from public.vw_jason_decision_digest where ticket_code = ca;
    if t is distinct from (select array_agg(x order by x) from unnest(array[cpa, cpg]) x) then
      msg := msg || format('[fixture a attached %s] ', t);
    end if;
    if exists (select 1 from public.vw_jason_decision_digest where ticket_code in (cpg, cpa)) then msg := msg || '[probe listed] '; end if;
    if not exists (select 1 from public.vw_jason_decision_digest where ticket_code = cb) then msg := msg || '[pending proposal missing] '; end if;
    if exists (select 1 from public.vw_jason_decision_digest where ticket_code in ('SB-520','SB-549','SB-553','39P-027')) then
      msg := msg || '[live escalation listed] ';
    end if;
    if exists (select 1 from public.work_items where ticket_code = 'SB-413' and status = 'awaiting_jason' and not archived)
       and not exists (select 1 from public.vw_jason_decision_digest where ticket_code = 'SB-413' and 'SB-520' = any(escalations_attached)) then
      msg := msg || '[SB-413 missing SB-520] ';
    end if;
    v := public.jason_decision_digest();
    select count(*) into n from public.vw_jason_decision_digest;
    if (v->>'total')::int <> n then msg := msg || format('[total %s vs view %s] ', v->>'total', n); end if;
    if not exists (select 1 from jsonb_array_elements(v->'items') i where i->>'ticket_code' = ca
                     and i->'escalations_attached' ? cpg) then msg := msg || '[function item a] '; end if;
    if (v->>'noop_escalations')::int < 3 then msg := msg || format('[noop %s] ', v->>'noop_escalations'); end if;
    -- as the owner's authenticated session
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    v := public.jason_decision_digest();
    reset role;
    perform set_config('request.jwt.claims', '{}', true);
    select count(*) into k from public.vw_jason_decision_digest where user_id = ub;
    if (v->>'total')::int <> k then msg := msg || format('[owner total %s vs %s] ', v->>'total', k); end if;
    r := r || jsonb_build_object('TC-SB554-5', case when msg = '' then 'pass' else 'FAIL: ' || msg end);
    r := r || jsonb_build_object('TC-SB554-5.evidence', format('digest rows %s, owner session total %s, noop escalations %s, fixture a attached %s',
           n, k, v->>'noop_escalations', t));
  exception when others then
    reset role;
    r := r || jsonb_build_object('TC-SB554-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-6: thresholds and order
  begin
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, updated_at)
      values (pj, ub, 'qa-sb554 aging critical', 'chore', 'awaiting_jason', 'critical', 'not_required', now() - interval '5 days')
      returning id, ticket_code into h1, k1;
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, updated_at)
      values (pj, ub, 'qa-sb554 aging high', 'chore', 'awaiting_jason', 'high', 'not_required', now() - interval '2 days')
      returning id, ticket_code into h2, k2;
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, updated_at)
      values (pj, ub, 'qa-sb554 aging low', 'chore', 'awaiting_jason', 'low', 'not_required', now() - interval '40 days')
      returning id, ticket_code into h3, k3;
    insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, updated_at)
      values (pj, ub, 'qa-sb554 aging medium', 'chore', 'awaiting_jason', 'medium', 'not_required', now() - interval '1 day')
      returning id, ticket_code into h4, k4;
    select array_agg(format('%s/%s/%s', aging_threshold_days, aging_breached, waiting_days) order by rank)
      into t
      from public.vw_jason_decision_digest where ticket_code in (k1, k2, k3, k4);
    select string_agg(ticket_code, ',' order by rank) into st2
      from public.vw_jason_decision_digest where ticket_code in (k1, k2, k3, k4);
    r := r || jsonb_build_object('TC-SB554-6', case
           when t = array['3/true/5.0','7/false/2.0','14/false/1.0','30/true/40.0']
            and st2 = k1 || ',' || k2 || ',' || k4 || ',' || k3
            and not exists (select 1 from public.vw_jason_decision_digest where ticket_code = ce)
           then 'pass' else format('FAIL: %s order %s', t, st2) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-7: posture
  begin
    k := 0;
    if exists (select 1 from pg_class where oid = 'public.vw_jason_decision_digest'::regclass
                 and reloptions @> array['security_invoker=true']) then k := k + 1; end if;
    if not has_table_privilege('anon', 'public.vw_jason_decision_digest', 'select') then k := k + 1; end if;
    if not has_function_privilege('anon', 'public.jason_decision_digest()', 'execute')
       and has_function_privilege('authenticated', 'public.jason_decision_digest()', 'execute') then k := k + 1; end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_escalation_blocker_class'
                 and tgrelid = 'public.work_items'::regclass and tgenabled = 'O') then k := k + 1; end if;
    if not exists (select 1 from pg_proc where oid in ('public.jason_blocker_class(text[])'::regprocedure,
                                                       'public.classify_escalation_on_insert()'::regprocedure,
                                                       'public.jason_decision_digest()'::regprocedure) and prosecdef) then k := k + 1; end if;
    if public.escalation_gate_mode('SB-554') = 'warn' and public.escalation_gate_mode('SB-526') = 'warn' then k := k + 1; end if;
    if (select provolatile from pg_proc where oid = 'public.escalation_subject_codes(jsonb)'::regprocedure) = 'i' then k := k + 1; end if;
    r := r || jsonb_build_object('TC-SB554-7', case when k = 7 then 'pass' else format('FAIL: %s of 7 posture checks', k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB554-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB554-8: enforce mode refuses probe A
  begin
    begin
      execute $ddl$create or replace function public.escalation_gate_mode(p_gate text)
        returns text language sql stable set search_path = public as $f$ select 'enforce'::text $f$$ddl$;
      st := 'ok';
      begin
        insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
          values (pj, ub, 'ESCALATION: qa-sb554 probe A enforce', 'chore', 'todo', 'high', 'not_required',
                  jsonb_build_object('blocker_ref', ca));
      exception when others then st := sqlstate; msg := sqlerrm;
      end;
      st2 := 'ok';
      begin
        insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
          values (pj, ub, 'ESCALATION: qa-sb554 probe B enforce', 'chore', 'todo', 'high', 'not_required',
                  jsonb_build_object('upstream_ticket', cd));
      exception when others then st2 := sqlstate;
      end;
      r := r || jsonb_build_object('TC-SB554-8', case
             when st = 'P0554' and msg like 'ESCALATION-003:%' and st2 = 'ok' and public.escalation_gate_mode('x') = 'enforce' then 'pass'
             else format('FAIL: probe A %s, probe B %s', st, st2) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB554-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    if public.escalation_gate_mode('SB-554') <> 'warn' then
      r := r || jsonb_build_object('TC-SB554-8', 'FAIL: gate mode not restored inside the suite');
    end if;
  end;

  reset role;
  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'JASON_DECISION_DIGEST PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'JASON_DECISION_DIGEST FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
