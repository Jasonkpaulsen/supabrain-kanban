-- SB-652: destructive-SQL audit. TC-SB652-01 .. -08.
--
-- Run as postgres via execute_sql AFTER SB-651 (before it, the hosted MCP's hidden confirmation
-- hangs on this DO block). One transaction that always ends by raising, so no fixture and no audit
-- row survives. Pass = the raised message starts with "SQL_AUDIT PASS". The message carries
-- counts and verdicts only, never row content.
-- Every step with a side effect runs on its own line, in order (AND has no evaluation order).

do $suite$
declare
  r jsonb := '{}'::jsonb; fails int; n bigint; base bigint; t0 timestamptz; d_base interval; d_trig interval;
  wid uuid; aid uuid; cid uuid; pid uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  st text;
begin
  select count(*) into base from public.sql_audit_log;

  -- TC-SB652-01: structure
  r := r || jsonb_build_object('TC-SB652-01.structure', case
         when (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relnamespace = 'public'::regnamespace and t.tgname = 'sql_audit_row_removal') = 12
          and (select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relnamespace = 'public'::regnamespace and t.tgname = 'sql_audit_truncation') = 12
          and exists (select 1 from pg_event_trigger where evtname = 'sql_audit_object_removal'
                       and evtevent = 'sql_drop' and evtenabled <> 'D')
          and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                and p.proname in ('sql_audit_row_removal', 'sql_audit_truncation', 'sql_audit_object_removal',
                                  'sql_audit_log_guard', 'sql_audit_caller_uid')
                and p.proconfig = array['search_path=""']) = 5
          and not (select prosecdef from pg_proc where oid = 'public.sql_audit_object_removal'::regproc)
          and public.sql_audit_caller_uid() is null
          and (select relrowsecurity from pg_class where oid = 'public.sql_audit_log'::regclass)
          and not exists (select 1 from public.vw_oauth_client_coverage_gaps where table_name = 'sql_audit_log')
         then 'pass' else 'FAIL' end);

  -- TC-SB652-02: client roles cannot read, write or forge audit rows (tested as the role)
  begin
    set local role anon;
    begin perform 1 from public.sql_audit_log limit 1; st := 'ok'; exception when others then st := sqlstate; end;
    reset role;
  end;
  r := r || jsonb_build_object('TC-SB652-02.anon_read', case when st = '42501' then 'pass' else 'FAIL:' || st end);
  begin
    set local role authenticated;
    begin perform 1 from public.sql_audit_log limit 1; st := 'ok'; exception when others then st := sqlstate; end;
    reset role;
  end;
  r := r || jsonb_build_object('TC-SB652-02.authenticated_read', case when st = '42501' then 'pass' else 'FAIL:' || st end);
  begin
    set local role authenticated;
    begin
      insert into public.sql_audit_log (operation, schema_name, object_name, object_type, db_role, session_role)
      values ('drop', 'public', 'forged', 'table', 'x', 'x');
      st := 'ok';
    exception when others then st := sqlstate; end;
    reset role;
  end;
  r := r || jsonb_build_object('TC-SB652-02.authenticated_forge', case when st = '42501' then 'pass' else 'FAIL:' || st end);

  -- TC-SB652-03: DELETE is audited once per statement, with the right count, and 0-row deletes are not
  insert into public.work_items (user_id, project_id, title, type, status, priority, approval_status)
  values (ub, pid, 'qa-sb652 fixture A', 'chore', 'backlog', 'low', 'not_required') returning id into wid;
  insert into public.work_items (user_id, project_id, title, type, status, priority, approval_status)
  values (ub, pid, 'qa-sb652 fixture B', 'chore', 'backlog', 'low', 'not_required');
  delete from public.work_items where title like 'qa-sb652 fixture %';
  r := r || jsonb_build_object('TC-SB652-03.delete_counted', case
         when (select count(*) from public.sql_audit_log where id is not null and created_at = now()
                and operation = 'delete' and object_name = 'work_items' and rows_affected = 2) = 1
         then 'pass' else 'FAIL' end);
  delete from public.work_items where title = 'qa-sb652 no such row';
  r := r || jsonb_build_object('TC-SB652-03.zero_rows_silent', case
         when (select count(*) from public.sql_audit_log where created_at = now() and object_name = 'work_items') = 1
         then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB652-03.no_row_content', case
         when not exists (select 1 from public.sql_audit_log l where l.created_at = now()
                           and to_jsonb(l)::text like '%qa-sb652 fixture%')
         then 'pass' else 'FAIL' end);

  -- TC-SB652-04: DROP of a public object and DROP COLUMN are audited, by identity
  create table public.qa_sb652_scratch (id int, extra text);
  alter table public.qa_sb652_scratch drop column extra;
  drop table public.qa_sb652_scratch;
  r := r || jsonb_build_object('TC-SB652-04.drop_audited', case
         when (select count(*) from public.sql_audit_log where created_at = now() and operation = 'drop'
                and object_name = 'public.qa_sb652_scratch' and object_type = 'table') = 1
          and (select count(*) from public.sql_audit_log where created_at = now() and operation = 'drop'
                and object_type = 'table column' and object_name like 'public.qa_sb652_scratch.extra') = 1
         then 'pass' else 'FAIL' end);

  -- TC-SB652-05: the alerts view shows DROP and big deletes, not small ones
  r := r || jsonb_build_object('TC-SB652-05.alerts_view', case
         when exists (select 1 from public.vw_destructive_sql_alerts where operation = 'drop'
                       and object_name = 'public.qa_sb652_scratch')
          and not exists (select 1 from public.vw_destructive_sql_alerts where operation = 'delete'
                           and object_name = 'work_items' and rows_affected = 2)
         then 'pass' else 'FAIL' end);

  -- TC-SB652-06: append-only, even for postgres
  begin update public.sql_audit_log set object_name = 'tampered' where created_at = now(); st := 'ok';
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB652-06.no_update', case when st = '42501' then 'pass' else 'FAIL:' || st end);
  begin delete from public.sql_audit_log where created_at = now(); st := 'ok';
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB652-06.no_delete', case when st = '42501' then 'pass' else 'FAIL:' || st end);

  -- TC-SB652-07: a cascade is recorded (parent at depth 1, children below) and the view sums it
  insert into public.test_cases (user_id, project_id, title, description, category, test_type, test_steps, expected_result)
  values (ub, pid, 'qa-sb652 cascade fixture', 'fixture', 'functional', 'manual', 'none', 'none') returning id into cid;
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652', 'pass', 'qa_initial', 'fixture' from generate_series(1, 30);
  delete from public.test_cases where id = cid;
  r := r || jsonb_build_object('TC-SB652-07.cascade', case
         when (select count(*) from public.sql_audit_log where created_at = now() and object_name = 'test_cases'
                and rows_affected = 1 and trigger_depth = 1) = 1
          and (select sum(rows_affected) from public.sql_audit_log where created_at = now()
                and object_name = 'test_runs' and trigger_depth > 1) = 30
          and exists (select 1 from public.vw_destructive_sql_alerts where object_name = 'test_runs' and rows_affected = 30)
         then 'pass' else 'FAIL' end);

  -- TC-SB652-08: cost. 1,000-row delete with the trigger within 2x of the same delete without it
  insert into public.test_cases (user_id, project_id, title, description, category, test_type, test_steps, expected_result)
  values (ub, pid, 'qa-sb652 perf fixture', 'fixture', 'functional', 'manual', 'none', 'none') returning id into cid;
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652-base', 'pass', 'qa_initial', 'fixture' from generate_series(1, 1000);
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652-trig', 'pass', 'qa_initial', 'fixture' from generate_series(1, 1000);
  alter table public.test_runs disable trigger sql_audit_row_removal;
  t0 := clock_timestamp();
  delete from public.test_runs where executed_by = 'qa-sb652-base';
  d_base := clock_timestamp() - t0;
  alter table public.test_runs enable trigger sql_audit_row_removal;
  t0 := clock_timestamp();
  delete from public.test_runs where executed_by = 'qa-sb652-trig';
  d_trig := clock_timestamp() - t0;
  r := r || jsonb_build_object('TC-SB652-08.cost', case
         when d_trig <= greatest(d_base * 2, interval '50 milliseconds') then 'pass'
         else 'FAIL:' || d_base::text || '/' || d_trig::text end,
       'TC-SB652-08.timings_ms', round(extract(epoch from d_base) * 1000) || '/' || round(extract(epoch from d_trig) * 1000));

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass' and key <> 'TC-SB652-08.timings_ms';
  if fails = 0 then
    raise exception 'SQL_AUDIT PASS (% checks) %', (select count(*) from jsonb_object_keys(r)), r;
  else
    raise exception 'SQL_AUDIT FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)), r;
  end if;
end
$suite$;
