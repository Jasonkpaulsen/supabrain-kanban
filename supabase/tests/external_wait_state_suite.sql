-- External-wait state suite: TC-SB593-1..5 and the catalog half of TC-SB593-7 (SB-593; ADR-FLOW-005 D1-D3).
--
-- Run as postgres. One transaction that always ends by raising, so no fixture it inserts
-- survives. Fixtures are SB work items ZZW-1..3 with synthetic meta. If a gate parks or
-- refuses a fixture, that case records 'blocked: <sqlstate or status>' instead of FAIL.
-- Pass = the raised message starts with "EXTERNAL_WAIT_STATE PASS". The message carries only
-- counts, statuses and sqlstates, never ticket titles or meta values.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  sb constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  rb constant text := '__sb593_rollback__';
  d  constant date := current_date;
  r jsonb := '{}'::jsonb;
  f1 uuid; f2 uuid; f3 uuid;
  n int; m int; k int; j int; fails int; st text; msg text; s0 bigint; s1 bigint; e0 bigint; e1 bigint; o0 bigint; o1 bigint;
begin
  -- ------------------------------------------------ TC-SB593-1: classifier truth table (a..g)
  begin
    msg := '';
    if public.work_item_wait_state('{}'::jsonb, d + 3, d) is not null then msg := msg || 'a '; end if;
    if public.work_item_wait_state('{"awaiting_external":"false"}'::jsonb, d + 3, d) is not null
       or public.work_item_wait_state('{"awaiting_external":"FALSE"}'::jsonb, d + 3, d) is not null then msg := msg || 'b '; end if;
    if public.work_item_wait_state('{"awaiting_external":""}'::jsonb, d + 3, d) is not null
       or public.work_item_wait_state('{"awaiting_external":"   "}'::jsonb, d + 3, d) is not null then msg := msg || 'c '; end if;
    if public.work_item_wait_state(jsonb_build_object('awaiting_external', 'P', 'external_clock_expires', (d + 5)::text), null, d) is distinct from 'waiting_on_track'
       or public.work_item_wait_state(jsonb_build_object('awaiting_external', 'P', 'external_clock_expires', d::text), d - 9, d) is distinct from 'waiting_on_track'
       or public.external_wait_clock(jsonb_build_object('external_clock_expires', (d + 5)::text), d + 1) is distinct from d + 5 then msg := msg || 'd '; end if;
    if public.work_item_wait_state(jsonb_build_object('awaiting_external', 'P', 'external_clock_expires', (d - 1)::text), d + 9, d) is distinct from 'external_clock_expired'
       or public.work_item_wait_state('{"awaiting_external":"P"}'::jsonb, d - 1, d) is distinct from 'external_clock_expired' then msg := msg || 'e '; end if;
    if public.work_item_wait_state('{"awaiting_external":"P"}'::jsonb, null, d) is distinct from 'waiting_no_clock'
       or public.work_item_wait_state('{"awaiting_external":"P","external_clock_expires":"soon"}'::jsonb, null, d) is distinct from 'waiting_no_clock' then msg := msg || 'f '; end if;
    if public.external_wait_clock('{"external_clock_expires":"2026-13-45"}'::jsonb, d + 3) is distinct from d + 3
       or public.external_wait_clock('{"external_clock_expires":"soon"}'::jsonb, d + 3) is distinct from d + 3
       or public.external_wait_clock('{"external_clock_expires":"2026-02-30"}'::jsonb, null) is not null
       or public.work_item_wait_state('{"awaiting_external":"P","external_clock_expires":"2026-13-45"}'::jsonb, d + 3, d) is distinct from 'waiting_on_track'
       or public.work_item_wait_state('{"awaiting_external":"true"}'::jsonb, d + 3, d) is distinct from 'waiting_on_track' then msg := msg || 'g '; end if;
    r := r || jsonb_build_object('TC-SB593-1', case when msg = '' then 'pass' else 'FAIL: rows ' || msg end);
  exception when others then
    r := r || jsonb_build_object('TC-SB593-1', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB593-2: 39P-026 listed as on track via due_date
  begin
    select count(*) into n from public.v_external_wait_status where ticket_code = '39P-026';
    select count(*) into m from public.v_external_wait_status
     where ticket_code = '39P-026' and wait_state = 'waiting_on_track' and clock_expires = date '2026-11-06'
       and clock_source = 'due_date' and severity = 'info' and external_party is not null and project_key = '39P';
    r := r || jsonb_build_object('TC-SB593-2', case when n = 1 and m = 1 then 'pass'
           else format('FAIL: rows %s, matching %s', n, m) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB593-2', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB593-3: stale_wip_gt3d recompute; on-track excluded, expired counted
  begin
    begin
      select stale_wip_gt3d into s0 from public.vw_audit_health_checks;
      select count(*) into n from public.work_items w
       where w.status = 'in_progress' and w.updated_at < now() - interval '3 days'
         and coalesce(public.work_item_wait_state(w.meta, w.due_date), 'x') not in ('waiting_on_track', 'waiting_no_clock');
      select external_clock_expired, external_wait_on_track into e0, o0 from public.jarvis_ops_metrics where user_id = ub;
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level, meta, updated_at)
      values (sb, ub, 'ZZW-1', 'wait fixture on track', 'task', 'in_progress', 'low', 'not_required', 1,
              jsonb_build_object('awaiting_external', 'Fixture Agency', 'external_clock_expires', (d + 10)::text), now() - interval '5 days')
      returning id into f1;
      select stale_wip_gt3d into s1 from public.vw_audit_health_checks;
      select external_wait_on_track into o1 from public.jarvis_ops_metrics where user_id = ub;
      msg := format('recompute %s view %s; on-track fixture stale delta %s, on_track delta %s', n, s0, s1 - s0, o1 - o0);
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level, meta, updated_at)
      values (sb, ub, 'ZZW-2', 'wait fixture expired', 'task', 'in_progress', 'low', 'not_required', 1,
              jsonb_build_object('awaiting_external', 'Fixture Agency', 'external_clock_expires', (d - 1)::text), now() - interval '5 days')
      returning id into f2;
      select stale_wip_gt3d into j from public.vw_audit_health_checks;
      select external_clock_expired into e1 from public.jarvis_ops_metrics where user_id = ub;
      select count(*) into k from public.v_external_wait_status
       where id = f2 and wait_state = 'external_clock_expired' and severity = 'escalate' and clock_source = 'meta' and days_to_clock = -1;
      -- moving the on-track fixture's clock to yesterday flips it too
      update public.work_items set meta = meta || jsonb_build_object('external_clock_expires', (d - 1)::text) where id = f1;
      select count(*) into m from public.v_external_wait_status where id = f1 and wait_state = 'external_clock_expired';
      r := r || jsonb_build_object('TC-SB593-3', case
             when n = s0 and s1 = s0 and o1 = o0 + 1 and j = s0 + 1 and e1 = e0 + 1 and k = 1 and m = 1 then 'pass'
             else format('FAIL: %s; expired fixture stale delta %s, expired delta %s, escalate rows %s, flipped %s', msg, j - s0, e1 - e0, k, m) end);
      r := r || jsonb_build_object('TC-SB593-3.evidence', format('%s; expired fixture stale delta %s, external_clock_expired delta %s', msg, j - s0, e1 - e0));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB593-3', case when f1 is null or f2 is null then 'blocked: ' || sqlstate else 'FAIL: error ' || sqlstate end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB593-4: four registry rows
  begin
    select count(*) into n from public.meta_key_registry
     where table_name = 'work_items' and owner = 'System Architect'
       and key_name in ('awaiting_external', 'external_ref', 'external_since', 'external_clock_expires');
    r := r || jsonb_build_object('TC-SB593-4', case when n = 4 then 'pass' else format('FAIL: %s of 4 rows', n) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB593-4', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB593-5: a waiting review item is skipped by both review SLA views
  begin
    begin
      st := 'insert';
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level, meta)
      values (sb, ub, 'ZZW-3', 'wait fixture review', 'task', 'in_progress', 'low', 'not_required', 1,
              jsonb_build_object('awaiting_external', 'Fixture Agency'))
      returning id into f3;
      st := 'to_review';
      update public.work_items set status = 'review', assignee = 'Jason Paulsen' where id = f3;
      select status into msg from public.work_items where id = f3;
      if msg <> 'review' then
        r := r || jsonb_build_object('TC-SB593-5', 'blocked: fixture status ' || msg);
        raise exception '%', rb;
      end if;
      st := 'backdate';
      update public.work_items set review_entered_at = now() - interval '80 hours' where id = f3;
      select count(*) into n from public.v_review_sla_breaches where id = f3;
      select count(*) into m from public.v_review_dwell_alerts where id = f3;
      st := 'unwait';
      update public.work_items set meta = meta - 'awaiting_external' where id = f3;
      select count(*) into k from public.v_review_sla_breaches where id = f3;
      select count(*) into j from public.v_review_dwell_alerts where id = f3;
      r := r || jsonb_build_object('TC-SB593-5', case when n = 0 and m = 0 and k = 1 and j = 1 then 'pass'
             else format('FAIL: waiting %s/%s, not waiting %s/%s', n, m, k, j) end);
      r := r || jsonb_build_object('TC-SB593-5.evidence', format('waiting: breaches %s dwell %s; key removed: breaches %s dwell %s', n, m, k, j));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB593-5', case when st in ('insert', 'to_review') then 'blocked: ' || st || ' ' || sqlstate
                                                       else 'FAIL: error ' || st || ' ' || sqlstate end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB593-7 (catalog half): posture and column shape
  -- v_external_wait_status has 17 columns since SB-603 appended data_quality_issue (ADR-FLOW-005 D2a).
  begin
    select count(*) into n from pg_class c
     where c.oid = 'public.v_external_wait_status'::regclass and c.reloptions @> array['security_invoker=true']
       and not has_table_privilege('anon', c.oid, 'select') and has_table_privilege('authenticated', c.oid, 'select');
    select count(*) into m from pg_proc p
     where p.oid in ('public.external_wait_clock(jsonb,date)'::regprocedure, 'public.work_item_wait_state(jsonb,date,date)'::regprocedure)
       and not p.prosecdef and p.proconfig @> array['search_path=public']
       and has_function_privilege('pg_read_all_data', p.oid, 'execute');
    select count(*) into k from pg_proc p
     where p.oid = 'public.review_sla_sweep()'::regprocedure and p.prosecdef
       and strpos(pg_get_functiondef(p.oid), 'work_item_wait_state(meta, due_date) IS NULL') > 0;
    select string_agg(format('%s=%s', relname, cnt), ',' order by relname) into msg from (
      select c.relname, count(a.attnum) cnt from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and a.atttypid <> 0
       where c.relnamespace = 'public'::regnamespace
         and c.relname in ('vw_audit_health_checks', 'jarvis_ops_metrics', 'v_review_dwell_alerts', 'v_review_sla_breaches', 'v_external_wait_status')
         and c.reloptions @> array['security_invoker=true']
       group by c.relname) x;
    r := r || jsonb_build_object('TC-SB593-7', case
           when n = 1 and m = 2 and k = 1
            and msg = 'jarvis_ops_metrics=20,v_external_wait_status=17,v_review_dwell_alerts=10,v_review_sla_breaches=9,vw_audit_health_checks=7' then 'pass'
           else format('FAIL: view %s, functions %s, sweep %s, columns %s', n, m, k, msg) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB593-7', 'FAIL: error ' || sqlstate);
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass' and value not like 'blocked:%';
  if fails = 0 then
    raise exception 'EXTERNAL_WAIT_STATE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'EXTERNAL_WAIT_STATE FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
