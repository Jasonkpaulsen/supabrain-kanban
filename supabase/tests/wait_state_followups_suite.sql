-- Wait-state follow-ups suite: TC-SB601-1, TC-SB602-1, TC-SB602-2, TC-SB603-1, TC-SB603-2, TC-SB604-1
-- (SB-601..604; ADR-FLOW-005 amendment 1, D2a, D3a, D12). TC-SB603-3 is the re-run of
-- external_wait_state_suite.sql.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture, temp table or
-- activity_log row it creates survives. Fixtures are SB work items ZZF-1..10 with synthetic meta.
-- If a gate parks or refuses a fixture, that case records 'blocked: <step> <sqlstate>' instead of FAIL.
-- Pass = the raised message starts with "WAIT_STATE_FOLLOWUPS PASS". The message carries only
-- counts, codes, states and sqlstates, never titles or meta values.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  sb constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  rb constant text := '__sb601_rollback__';
  d  constant date := current_date;
  r jsonb := '{}'::jsonb;
  f5 uuid; f6 uuid;
  n int; m int; fails int; st text; msg text; t text[]; v jsonb;
begin
  execute $f$create function pg_temp.fx(p_code text, p_status text, p_due date, p_meta jsonb)
    returns uuid language plpgsql as $b$
    declare v uuid;
    begin
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status,
                                     authority_level, due_date, meta)
      values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', p_code,
              'wait follow-up fixture', 'task', p_status, 'low', 'not_required', 1, p_due, coalesce(p_meta, '{}'::jsonb))
      returning id into v;
      return v;
    end $b$$f$;

  -- ------------------------------------------------ TC-SB603-1: external_wait_data_quality truth table
  begin
    msg := '';
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"2026-11-06T00:00:00Z"}', d) is distinct from 'invalid_clock' then msg := msg || 'iso-ts '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":" 2026-11-06"}', d) is distinct from 'invalid_clock' then msg := msg || 'lead-space '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"2026-02-30"}', d) is distinct from 'invalid_clock' then msg := msg || 'feb30 '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"0000-01-01"}', d) is distinct from 'invalid_clock' then msg := msg || 'year0 '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":20261106}', d) is distinct from 'invalid_clock' then msg := msg || 'number '; end if;
    if public.external_wait_data_quality('{"awaiting_external":{"name":"x"},"external_clock_expires":"2026-11-06"}', null) is distinct from 'non_text_party' then msg := msg || 'object '; end if;
    if public.external_wait_data_quality('{"awaiting_external":["x"]}', d) is distinct from 'non_text_party' then msg := msg || 'array '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P"}', null) is distinct from 'no_clock' then msg := msg || 'no-clock '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P"}', d) is not null then msg := msg || 'clean-due '; end if;
    if public.external_wait_data_quality(jsonb_build_object('awaiting_external', 'P', 'external_clock_expires', (d + 5)::text), null) is not null then msg := msg || 'clean-meta '; end if;
    if public.external_wait_data_quality('{"awaiting_external":true}', d) is not null then msg := msg || 'json-true '; end if;
    if public.external_wait_data_quality('{"awaiting_external":"P","external_clock_expires":"   "}', d) is not null then msg := msg || 'blank-clock '; end if;
    r := r || jsonb_build_object('TC-SB603-1', case when msg = '' then 'pass' else 'FAIL: rows ' || msg end);
  exception when others then
    r := r || jsonb_build_object('TC-SB603-1', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB603-2: the view surfaces issues; the classification does not move
  begin
    begin
      st := 'insert';
      perform pg_temp.fx('ZZF-7', 'in_progress', d + 5, '{"awaiting_external":"Agency","external_clock_expires":"2026-11-06T00:00:00Z"}');
      perform pg_temp.fx('ZZF-8', 'in_progress', null, jsonb_build_object('awaiting_external', '{"name":"x"}'::jsonb, 'external_clock_expires', (d + 5)::text));
      perform pg_temp.fx('ZZF-9', 'in_progress', d - 2, '{"awaiting_external":"Agency","external_clock_expires":"soon"}');
      perform pg_temp.fx('ZZF-10', 'in_progress', null, jsonb_build_object('awaiting_external', 'Agency', 'external_clock_expires', (d + 5)::text));
      st := 'read';
      select array_agg(format('%s/%s/%s/%s/%s/%s', v.ticket_code, v.wait_state, v.clock_source, v.severity,
                              coalesce(v.data_quality_issue, '-'), (v.external_party is null)::text) order by v.ticket_code)
        into t from public.v_external_wait_status v where v.ticket_code in ('ZZF-7', 'ZZF-8', 'ZZF-9', 'ZZF-10');
      select count(*) into n from public.v_external_wait_status v join public.work_items w on w.ticket_code = v.ticket_code
       where v.ticket_code like 'ZZF-%' and v.wait_state is distinct from public.work_item_wait_state(w.meta, w.due_date);
      r := r || jsonb_build_object('TC-SB603-2', case
             when t = array['ZZF-10/waiting_on_track/meta/info/-/false',
                            'ZZF-7/waiting_on_track/due_date_fallback/data_quality/invalid_clock/false',
                            'ZZF-8/waiting_on_track/meta/data_quality/non_text_party/true',
                            'ZZF-9/external_clock_expired/due_date_fallback/escalate/invalid_clock/false']
              and n = 0 then 'pass'
             else format('FAIL: %s; classification mismatches %s', t, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB603-2', 'blocked: ' || st || ' ' || sqlstate); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB602-1: whitespace and case are judged by the classifier
  begin
    begin
      st := 'insert';
      perform pg_temp.fx('ZZF-1', 'in_progress', d + 5, '{"awaiting_external":"  "}');
      perform pg_temp.fx('ZZF-2', 'in_progress', d + 5, '{"awaiting_external":"FALSE"}');
      perform pg_temp.fx('ZZF-3', 'in_progress', d + 5, '{"awaiting_external":" false "}');
      perform pg_temp.fx('ZZF-4', 'in_progress', d + 5, '{"awaiting_external":"Agency"}');
      st := 'read';
      select array_agg(format('%s/%s', ticket_code, coalesce(wait_state, 'null')) order by ticket_code) into t
        from public.v_open_work_wait_state where ticket_code in ('ZZF-1', 'ZZF-2', 'ZZF-3', 'ZZF-4');
      -- the stale_wip read the edge makes (status, wait_state is null), minus its age cut-off
      select count(*) into n from public.v_open_work_wait_state
       where status = 'in_progress' and wait_state is null and ticket_code in ('ZZF-1', 'ZZF-2', 'ZZF-3', 'ZZF-4');
      r := r || jsonb_build_object('TC-SB602-1', case
             when t = array['ZZF-1/null', 'ZZF-2/null', 'ZZF-3/null', 'ZZF-4/waiting_on_track'] and n = 3 then 'pass'
             else format('FAIL: %s; stale_wip candidates %s of 3', t, n) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB602-1', 'blocked: ' || st || ' ' || sqlstate); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB601-1: review_queue_aging's read skips a waiting review item
  begin
    begin
      st := 'insert';
      f5 := pg_temp.fx('ZZF-5', 'in_progress', d + 5, '{"awaiting_external":"Agency"}');
      f6 := pg_temp.fx('ZZF-6', 'in_progress', d + 5, null);
      st := 'to_review';
      update public.work_items set status = 'review', assignee = 'Jason Paulsen' where id in (f5, f6);
      select count(*) into n from public.work_items where id in (f5, f6) and status = 'review';
      if n <> 2 then
        r := r || jsonb_build_object('TC-SB601-1', format('blocked: %s of 2 fixtures reached review', n));
        raise exception '%', rb;
      end if;
      st := 'backdate';
      update public.work_items set review_entered_at = now() - interval '80 hours' where id in (f5, f6);
      -- the read review_queue_aging makes, at its default ageHours = 48
      select array_agg(ticket_code order by ticket_code) into t from public.v_open_work_wait_state
       where status = 'review' and wait_state is null and review_entered_at < now() - interval '48 hours'
         and ticket_code in ('ZZF-5', 'ZZF-6');
      r := r || jsonb_build_object('TC-SB601-1', case when t = array['ZZF-6'] then 'pass'
             else format('FAIL: listed %s', t) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB601-1', 'blocked: ' || st || ' ' || sqlstate); end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB602-2: view posture and coverage
  begin
    n := 0;
    if exists (select 1 from pg_class where oid = 'public.v_open_work_wait_state'::regclass and reloptions @> array['security_invoker=true']) then n := n + 1; end if;
    if not has_table_privilege('anon', 'public.v_open_work_wait_state', 'select') then n := n + 1; end if;
    if not has_table_privilege('authenticated', 'public.v_open_work_wait_state', 'select') then n := n + 1; end if;
    if has_table_privilege('service_role', 'public.v_open_work_wait_state', 'select') then n := n + 1; end if;
    if (select count(*) from public.v_open_work_wait_state)
       = (select count(*) from public.work_items where not archived and status not in ('done', 'cancelled')) then n := n + 1; end if;
    if (select count(*) from public.v_open_work_wait_state) = (select count(distinct ticket_code) from public.v_open_work_wait_state) then n := n + 1; end if;
    r := r || jsonb_build_object('TC-SB602-2', case when n = 6 then 'pass' else format('FAIL: %s of 6 checks', n) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB602-2', 'FAIL: error ' || sqlstate);
  end;

  -- ------------------------------------------------ TC-SB604-1: pinned search_path; a shadowing temp relation is ignored
  begin
    begin
      n := 0;
      select count(*) into m from pg_proc p
       where p.oid in ('public.review_sla_sweep()'::regprocedure, 'public.get_review_alerts(numeric,text)'::regprocedure)
         and p.prosecdef and p.proconfig = array['search_path=""']
         and not has_function_privilege('anon', p.oid, 'execute')
         and not has_function_privilege('authenticated', p.oid, 'execute')
         and has_function_privilege('service_role', p.oid, 'execute');
      if m = 2 then n := n + 1; end if;
      -- relations with the same names in pg_temp, each holding a sentinel row
      st := 'shadow';
      execute 'create temp table v_review_sla_breaches (ticket_code text, assignee text, hours_in_review numeric, breach_level text)';
      execute $x$insert into pg_temp.v_review_sla_breaches values ('ZZF-SENTINEL', 'nobody', 999, 'breach')$x$;
      execute 'create temp table v_review_dwell_alerts (id uuid, ticket_code text, title text, project_key text, assignee text,
                                                       hours_in_review numeric, breach_level text, severity_rank integer)';
      execute $x$insert into pg_temp.v_review_dwell_alerts values (gen_random_uuid(), 'ZZF-SENTINEL', 't', 'SB', 'nobody', 999, 'breach', 1)$x$;
      perform set_config('search_path', 'pg_temp, public', true);
      st := 'run';
      v := public.review_sla_sweep();
      if v ?& array['summary', 'breaches', 'overloaded', 'auto_stamped_count']
         and not exists (select 1 from jsonb_array_elements(v->'breaches') b where b->>'ticket' = 'ZZF-SENTINEL') then n := n + 1; end if;
      select count(*) into m from public.get_review_alerts(0) a where a.ticket_code = 'ZZF-SENTINEL';
      if m = 0 then n := n + 1; end if;
      perform set_config('search_path', 'public', true);
      select count(*) into m from public.get_review_alerts(0);
      if m = (select count(*) from public.v_review_dwell_alerts) then n := n + 1; end if;
      r := r || jsonb_build_object('TC-SB604-1', case when n = 4 then 'pass' else format('FAIL: %s of 4 checks', n) end);
      raise exception '%', rb;
    exception when others then
      perform set_config('search_path', 'public', true);
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB604-1', 'FAIL: error ' || st || ' ' || sqlstate); end if;
    end;
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'WAIT_STATE_FOLLOWUPS PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'WAIT_STATE_FOLLOWUPS FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
