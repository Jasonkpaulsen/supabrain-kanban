-- SB-652: destructive-SQL audit. TC-SB652-01 .. -08, -11, -13, -14.
--
-- Run as postgres via execute_sql AFTER SB-651 (before it, the hosted MCP's hidden confirmation
-- hangs on this DO block), or paste it into the Supabase SQL editor. One transaction that always
-- ends by raising, so no fixture, scratch object or audit row survives. Pass = the raised message
-- starts with "SQL_AUDIT PASS". The message carries counts, verdicts and timings only, never row
-- content. Every step with a side effect runs on its own line, in order (AND has no evaluation
-- order). TC-08 holds a lock on test_runs until the rollback: run it when that table is quiet.
--
-- Revision 2 (SupaBrain QA, comment c520c3c6): TC-07 no longer filters on trigger_depth (cascaded
-- child triggers fire at depth 1), TC-08 has no 50 ms floor and uses 10,000 rows, TC-02 forges as
-- service_role and as postgres and checks the guard's own message, TC-01 checks enabled state,
-- the transition table and the exact table list, and TC-11, TC-13 and TC-14 are added.
--
-- Revision 3 (passed 19/19, run by Jason in the SQL editor 2026-10-28): plain $$ quoting, and
-- every DDL and TRUNCATE inside the block runs through EXECUTE with no semicolon in
-- the string. The Supabase SQL editor splits scripts on statements it recognises (its new-table
-- RLS check), which cut the DO block in half at the first DROP COLUMN.

do $$
declare
  r jsonb := '{}'::jsonb; fails int; t0 timestamptz; d_base interval; d_trig interval;
  wid uuid; cid uuid; tid uuid; pid uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  st text; msg text;
  audited constant text[] := array['agents','decisions','image_assets','image_requests','memories','projects',
                                   'reference_items','skills','test_cases','test_runs','work_item_comments','work_items'];
begin
  -- TC-SB652-01: structure
  r := r || jsonb_build_object('TC-SB652-01.structure', case
         when (select array_agg(c.relname::text order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relnamespace = 'public'::regnamespace and t.tgname = 'sql_audit_row_removal'
                  and t.tgenabled = 'O' and t.tgoldtable = 'removed_rows') = audited
          and (select array_agg(c.relname::text order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
                where c.relnamespace = 'public'::regnamespace and t.tgname = 'sql_audit_truncation'
                  and t.tgenabled = 'O') = audited
          and exists (select 1 from pg_event_trigger where evtname = 'sql_audit_object_removal'
                       and evtevent = 'sql_drop' and evtenabled = 'O')
          and (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
                and p.proname in ('sql_audit_row_removal', 'sql_audit_truncation', 'sql_audit_object_removal',
                                  'sql_audit_log_guard', 'sql_audit_caller_uid')
                and p.proconfig = array['search_path=""']) = 5
          and not (select prosecdef from pg_proc where oid = 'public.sql_audit_object_removal'::regproc)
          and public.sql_audit_caller_uid() is null
          and (select relrowsecurity from pg_class where oid = 'public.sql_audit_log'::regclass)
          and not exists (select 1 from public.vw_oauth_client_coverage_gaps where table_name = 'sql_audit_log')
         then 'pass' else 'FAIL' end);

  -- TC-SB652-02: client roles cannot read or forge, tested as the role
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
    begin perform 1 from public.vw_destructive_sql_alerts limit 1; st := 'ok'; exception when others then st := sqlstate; end;
    reset role;
  end;
  r := r || jsonb_build_object('TC-SB652-02.authenticated_view', case when st = '42501' then 'pass' else 'FAIL:' || st end);
  begin
    set local role service_role;
    begin
      insert into public.sql_audit_log (operation, schema_name, object_name, object_type, db_role, session_role)
      values ('drop', 'public', 'forged', 'table', 'x', 'x');
      st := 'ok';
    exception when others then st := sqlstate; end;
    reset role;
  end;
  r := r || jsonb_build_object('TC-SB652-02.service_role_forge', case when st = '42501' then 'pass' else 'FAIL:' || st end);

  -- TC-SB652-13: postgres outside the audit functions cannot forge either (the guard, not a grant)
  begin
    insert into public.sql_audit_log (operation, schema_name, object_name, object_type, db_role, session_role)
    values ('drop', 'public', 'forged', 'table', 'x', 'x');
    st := 'ok'; msg := '';
  exception when others then st := sqlstate; msg := sqlerrm; end;
  r := r || jsonb_build_object('TC-SB652-13.postgres_forge', case when st = '42501' and msg like 'SB-652:%' then 'pass' else 'FAIL:' || st end);
  perform set_config('sb652.audit_writer', '', true);

  -- TC-SB652-03: DELETE is audited once per statement, with the right count, and 0-row deletes are not
  insert into public.work_items (user_id, project_id, title, type, status, priority, approval_status)
  values (ub, pid, 'qa-sb652 fixture A', 'chore', 'backlog', 'low', 'not_required') returning id into wid;
  insert into public.work_items (user_id, project_id, title, type, status, priority, approval_status)
  values (ub, pid, 'qa-sb652 fixture B', 'chore', 'backlog', 'low', 'not_required');
  delete from public.work_items where title like 'qa-sb652 fixture %';
  r := r || jsonb_build_object('TC-SB652-03.delete_counted', case
         when (select count(*) from public.sql_audit_log where created_at = now()
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
  execute 'create table public.qa_sb652_scratch (id int, extra text)';
  execute 'alter table public.qa_sb652_scratch drop column extra';
  execute 'drop table public.qa_sb652_scratch';
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
                           and object_name = 'work_items')
         then 'pass' else 'FAIL' end);

  -- TC-SB652-06: append-only, even for postgres
  begin update public.sql_audit_log set object_name = 'tampered' where created_at = now(); st := 'ok';
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB652-06.no_update', case when st = '42501' then 'pass' else 'FAIL:' || st end);
  begin delete from public.sql_audit_log where created_at = now(); st := 'ok';
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB652-06.no_delete', case when st = '42501' then 'pass' else 'FAIL:' || st end);

  -- TC-SB652-11: TRUNCATE is recorded, and TRUNCATE of the audit log is refused
  execute 'create table public.qa_sb652_trunc (id int)';
  execute 'create trigger sql_audit_truncation after truncate on public.qa_sb652_trunc for each statement execute function public.sql_audit_truncation()';
  execute 'insert into public.qa_sb652_trunc values (1), (2)';
  execute 'truncate public.qa_sb652_trunc';
  r := r || jsonb_build_object('TC-SB652-11.truncate_audited', case
         when (select count(*) from public.sql_audit_log where created_at = now() and operation = 'truncate'
                and object_name = 'qa_sb652_trunc' and rows_affected is null) = 1
         then 'pass' else 'FAIL' end);
  begin execute 'truncate public.sql_audit_log'; st := 'ok';
  exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB652-11.audit_log_truncate_refused', case when st = '42501' then 'pass' else 'FAIL:' || st end);

  -- TC-SB652-07: a cascade is recorded and the view sums it
  insert into public.test_cases (user_id, project_id, title, description, category, test_type, test_steps, expected_result)
  values (ub, pid, 'qa-sb652 cascade fixture', 'fixture', 'functional', 'manual', 'none', 'none') returning id into cid;
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652', 'pass', 'qa_initial', 'fixture' from generate_series(1, 30);
  delete from public.test_cases where id = cid;
  r := r || jsonb_build_object('TC-SB652-07.cascade', case
         when (select count(*) from public.sql_audit_log where created_at = now() and object_name = 'test_cases'
                and rows_affected = 1) = 1
          and (select sum(rows_affected) from public.sql_audit_log where created_at = now()
                and object_name = 'test_runs') = 30
          and exists (select 1 from public.vw_destructive_sql_alerts where object_name = 'test_runs' and rows_affected = 30)
         then 'pass' else 'FAIL' end);

  -- TC-SB652-14: caller attribution for an API-style delete, and a nested delete
  insert into public.work_items (user_id, project_id, title, type, status, priority, approval_status)
  values (ub, pid, 'qa-sb652 attribution fixture', 'chore', 'backlog', 'low', 'not_required') returning id into tid;
  insert into public.work_item_comments (work_item_id, user_id, body) values (tid, ub, 'qa-sb652 attribution comment');
  insert into public.work_item_comments (work_item_id, user_id, body) values (tid, ub, 'qa-sb652 nested comment');
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  begin
    set local role authenticated;
    begin delete from public.work_item_comments where body = 'qa-sb652 attribution comment'; st := 'ok';
    exception when others then st := sqlstate; end;
    reset role;
  end;
  perform set_config('request.jwt.claims', '', true);
  r := r || jsonb_build_object('TC-SB652-14.attribution', case
         when st = 'ok' and (select count(*) from public.sql_audit_log where created_at = now()
                and object_name = 'work_item_comments' and rows_affected = 1
                and db_role = 'authenticated' and auth_uid = ub) = 1
         then 'pass' else 'FAIL:' || st end);
  execute 'create table public.qa_sb652_nest (id int)';
  execute format('create function public.qa_sb652_nest_fn() returns trigger language plpgsql set search_path to %L as %L', '',
    'begin delete from public.work_item_comments where body = ' || quote_literal('qa-sb652 nested comment') || chr(59)
    || ' return null' || chr(59) || ' end');
  execute 'create trigger qa_sb652_nest after insert on public.qa_sb652_nest for each statement execute function public.qa_sb652_nest_fn()';
  execute 'insert into public.qa_sb652_nest values (1)';
  r := r || jsonb_build_object('TC-SB652-14.nested', case
         when (select count(*) from public.sql_audit_log where created_at = now()
                and object_name = 'work_item_comments' and trigger_depth = 2) = 1
         then 'pass' else 'FAIL' end);

  -- TC-SB652-08: cost. A 10,000-row delete with the trigger within 2x of the same delete without it
  insert into public.test_cases (user_id, project_id, title, description, category, test_type, test_steps, expected_result)
  values (ub, pid, 'qa-sb652 perf fixture', 'fixture', 'functional', 'manual', 'none', 'none') returning id into cid;
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652-base', 'pass', 'qa_initial', 'fixture' from generate_series(1, 10000);
  insert into public.test_runs (user_id, test_case_id, executed_by, result, phase, evidence)
  select ub, cid, 'qa-sb652-trig', 'pass', 'qa_initial', 'fixture' from generate_series(1, 10000);
  execute 'alter table public.test_runs disable trigger sql_audit_row_removal';
  t0 := clock_timestamp();
  delete from public.test_runs where executed_by = 'qa-sb652-base';
  d_base := clock_timestamp() - t0;
  execute 'alter table public.test_runs enable trigger sql_audit_row_removal';
  t0 := clock_timestamp();
  delete from public.test_runs where executed_by = 'qa-sb652-trig';
  d_trig := clock_timestamp() - t0;
  r := r || jsonb_build_object('TC-SB652-08.cost', case
         when d_trig <= d_base * 2 then 'pass'
         else 'FAIL:' || d_base::text || '/' || d_trig::text end,
       'TC-SB652-08.timings_ms', round(extract(epoch from d_base) * 1000) || '/' || round(extract(epoch from d_trig) * 1000));

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass' and key <> 'TC-SB652-08.timings_ms';
  if fails = 0 then
    raise exception 'SQL_AUDIT PASS (% checks) %', (select count(*) from jsonb_object_keys(r)) - 1, r;
  else
    raise exception 'SQL_AUDIT FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)) - 1, r;
  end if;
end
$$;
