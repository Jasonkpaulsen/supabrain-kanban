-- SB-563 ticket cancellation suite (ADR-FLOW-004): TC-SB563-1..13.
-- One transaction that always ends in an exception, so nothing it writes is kept.
-- Marker: "CANCEL-SUITE PASS (13 checks)".
do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner (Jason)
  ua constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';   -- another signed-in user
  dev constant text := 'Supabase Platform Engineer';
  pm  constant text := 'SupaBrain Operations PM';
  jv  constant text := 'JARVIS — Master Orchestrator';
  r jsonb := '{}'::jsonb;
  sb uuid;
  f1 uuid; f2 uuid; f3 uuid; f4 uuid; f5 uuid; f6 uuid; f7 uuid; f8 uuid; f9 uuid; f10 uuid; f11 uuid;
  e1 uuid; c1 uuid; r1 uuid; r1code text;
  t text[]; st text; x record; m0 record; m1 record; k0 record; k1 record;
  v jsonb; fails int;
begin
  select id into sb from public.projects where project_key = 'SB';
  execute $f$create function pg_temp.try(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return coalesce(substring(sqlerrm from '^(CANCEL-[0-9]+|GOV-[0-9]+)'), sqlstate || ': ' || left(sqlerrm, 80));
    end $b$$f$;
  execute 'grant execute on function pg_temp.try(text) to authenticated';

  -- fixtures (ticket codes outside every project's numbering)
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-1', 'cancel fixture L1', 'task', 'backlog', 'low', 'not_required', 1) returning id into f1;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-2', 'cancel fixture L2', 'task', 'todo', 'low', 'not_required', 2) returning id into f2;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-3', 'cancel fixture L3', 'task', 'backlog', 'low', 'pending', 3) returning id into f3;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-4', 'cancel fixture L2 awaiting', 'task', 'awaiting_jason', 'low', 'pending', 2) returning id into f4;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-5', 'cancel fixture rejected', 'task', 'todo', 'low', 'rejected', 1) returning id into f5;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, completed_at)
  values (sb, ub, 'ZZC-6', 'cancel fixture done chore', 'chore', 'done', 'low', 'not_required', now() - interval '40 days') returning id into f6;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-7', 'cancel fixture LCE shape', 'task', 'awaiting_jason', 'low', 'pending', 3) returning id into f7;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-8', 'cancel fixture rpc', 'task', 'todo', 'low', 'not_required', 1) returning id into f8;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status)
  values (sb, ub, 'ZZC-9', 'cancel fixture null level', 'task', 'todo', 'low', 'not_required') returning id into f9;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-10', 'cancel fixture no tests no review', 'task', 'todo', 'low', 'pending', 1) returning id into f10;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZC-11', 'cancel fixture blocker', 'task', 'todo', 'low', 'not_required', 1) returning id into f11;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status)
  values (sb, ub, 'ZZC-20', 'cancel fixture replacement', 'task', 'todo', 'low', 'not_required') returning id, ticket_code into r1, r1code;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status)
  values (sb, ub, 'ZZC-30', 'cancel fixture epic', 'epic', 'todo', 'low', 'not_required') returning id into e1;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, parent_id, authority_level)
  values (sb, ub, 'ZZC-31', 'cancel fixture child', 'task', 'todo', 'low', 'not_required', e1, 1) returning id into c1;
  insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, f11, r1, 'blocks');

  -- TC-SB563-1: status + invariant
  t := array[
    pg_temp.try(format($q$update public.work_items set cancel_reason = 'wont_do' where id = %L$q$, f2)),
    pg_temp.try(format($q$update public.work_items set status = 'cancelled' where id = %L$q$, f2))];
  r := r || jsonb_build_object('TC-SB563-1', case
         when t = array['CANCEL-001','CANCEL-001']
          and exists (select 1 from pg_constraint where conname = 'work_items_cancel_fields_check')
          and exists (select 1 from pg_constraint where conname = 'work_items_status_check' and pg_get_constraintdef(oid) like '%cancelled%')
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-2: reason rules
  t := array[
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='duplicate', cancelled_by=%L where id=%L$q$, dev, f1)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='superseded', cancel_replaced_by=%L, cancelled_by=%L where id=%L$q$, f1, dev, f1)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancelled_by=%L where id=%L$q$, dev, f1)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='no_longer_relevant', cancel_note='ab', cancelled_by=%L where id=%L$q$, dev, f1)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='duplicate', cancel_replaced_by=%L, cancelled_by=%L where id=%L$q$, r1, dev, f1))];
  r := r || jsonb_build_object('TC-SB563-2', case
         when t = array['CANCEL-002','CANCEL-002','CANCEL-002','CANCEL-002','ok']
          and (select status = 'cancelled' and cancelled_at is not null and cancel_replaced_by = r1 from public.work_items where id = f1)
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-3: authority by level
  t := array[
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='not needed', cancelled_by=%L where id=%L$q$, dev, f2)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='not needed', cancelled_by=%L where id=%L$q$, pm, f2)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='not needed', cancelled_by=%L where id=%L$q$, pm, f3)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='not needed', cancelled_by='Jason' where id=%L$q$, f3)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='not needed', cancelled_by=%L where id=%L$q$, jv, f4)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='rejected_by_jason', cancel_note='declined', cancelled_by=%L where id=%L$q$, pm, f5)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='superseded', cancel_replaced_by=%L, cancelled_by='Jason' where id=%L$q$, r1, f4))];
  r := r || jsonb_build_object('TC-SB563-3', case
         when t = array['CANCEL-003','ok','CANCEL-003','ok','CANCEL-003','CANCEL-003','ok']
          and (select approval_status = 'rejected' and approved_by = 'Jason' from public.work_items where id = f4)
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-4: no QA / review / approval gate, never completed_at
  perform set_config('supabrain.cancel_backfill', 'on', true);
  t := array[
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='no_longer_relevant', cancel_note='nobody needs it', cancelled_by=%L where id=%L$q$, dev, f10)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='was declined', cancelled_by=%L where id=%L$q$, dev, f5)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='no_longer_relevant', cancel_note='closed by mistake', cancelled_by=%L, cancelled_at=now() - interval '30 days' where id=%L$q$, dev, f6))];
  perform set_config('supabrain.cancel_backfill', 'off', true);
  r := r || jsonb_build_object('TC-SB563-4', case
         when t = array['ok','ok','ok']
          and (select count(*) from public.work_items where id in (f10, f5, f6) and completed_at is null and status = 'cancelled') = 3
          and (select qa_status is null and cancelled_at < now() - interval '29 days' from public.work_items where id = f6)
          and not exists (select 1 from public.work_items where id in (f10, f5, f6) and meta ? 'approval_gate_exempt')
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-5: audit (f1 is L1, f9 is NULL level)
  perform pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='audit check', cancelled_by=%L where id=%L$q$, dev, f9));
  perform pg_temp.try(format($q$update public.work_items set status='backlog', meta = meta || '{"reopened_by":"SupaBrain QA"}' where id=%L$q$, f9));
  r := r || jsonb_build_object('TC-SB563-5', case
         when (select count(*) from public.governance_audit where work_item_id = f1 and to_status = 'cancelled') = 1
          and exists (select 1 from public.governance_audit where work_item_id = f1 and decision = 'cancelled' and decided_by = dev and notes like '%reason=duplicate%')
          and exists (select 1 from public.governance_audit where work_item_id = f9 and decision = 'cancelled' and notes like '%reason=wont_do%')
          and exists (select 1 from public.governance_audit where work_item_id = f9 and decision = 'reopened' and decided_by = 'SupaBrain QA')
         then 'pass' else 'FAIL: audit rows' end);

  -- TC-SB563-6: reopen rules
  t := array[
    pg_temp.try(format($q$update public.work_items set status='in_progress' where id=%L$q$, f1)),
    pg_temp.try(format($q$update public.work_items set status='done' where id=%L$q$, f1)),
    pg_temp.try(format($q$update public.work_items set status='backlog' where id=%L$q$, f1)),
    pg_temp.try(format($q$update public.work_items set status='todo' where id=%L$q$, f3)),
    pg_temp.try(format($q$update public.work_items set status='awaiting_jason' where id=%L$q$, f3))];
  r := r || jsonb_build_object('TC-SB563-6', case
         when t = array['CANCEL-005','CANCEL-005','ok','CANCEL-005','ok']
          and (select cancel_reason is null and cancelled_at is null and jsonb_array_length(meta->'cancel_history') = 1
                      and meta->'cancel_history'->0->>'reason' = 'duplicate' from public.work_items where id = f1)
          and (select approval_status = 'pending' from public.work_items where id = f3)
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-7: lock + no insert-as-cancelled
  t := array[
    pg_temp.try(format($q$update public.work_items set cancel_note='edited later' where id=%L$q$, f10)),
    pg_temp.try(format($q$insert into public.work_items (project_id, user_id, ticket_code, title, type, status) values (%L, %L, 'ZZC-99', 'x', 'task', 'cancelled')$q$, sb, ub))];
  r := r || jsonb_build_object('TC-SB563-7', case when t = array['CANCEL-006','CANCEL-007'] then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-8: parent guard
  t := array[
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='epic dropped', cancelled_by=%L where id=%L$q$, dev, e1)),
    pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='epic dropped', cancelled_by=%L where id=%L$q$, dev, c1))];
  select child_count, completed_child_count into k1 from public.kanban_board_view where id = e1;
  t := t || pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='epic dropped', cancelled_by=%L where id=%L$q$, dev, e1));
  r := r || jsonb_build_object('TC-SB563-8', case when t = array['CANCEL-004','ok','ok'] then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-9: metrics, board, archive, daily audit
  select total_items, done_items, cancelled_items into m0 from public.jarvis_ops_metrics where user_id = ub;
  select blocked_by_count into k0 from public.kanban_board_view where id = r1;
  perform pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='wont_do', cancel_note='metrics check', cancelled_by=%L where id=%L$q$, dev, f11));
  select total_items, done_items, cancelled_items into m1 from public.jarvis_ops_metrics where user_id = ub;
  v := public.archive_work_items(true, 14, false);
  r := r || jsonb_build_object('TC-SB563-9', case
         when m1.total_items = m0.total_items - 1 and m1.cancelled_items = m0.cancelled_items + 1 and m1.done_items = m0.done_items
          and k0.blocked_by_count = 1 and (select blocked_by_count from public.kanban_board_view where id = r1) = 0
          and k1.child_count = 0
          and v->'would_archive' ? f6::text
          and (select prosrc from pg_proc where oid = 'public.generate_daily_audit(uuid,uuid,date,uuid)'::regprocedure)
              like '%''cancelled'', COUNT(*) FILTER (WHERE status = ''cancelled'')%'
          and (select prosrc !~ 'NOT IN \(''done'',''backlog''\)' from pg_proc where oid = 'public.generate_daily_audit(uuid,uuid,date,uuid)'::regprocedure)
         then 'pass' else format('FAIL: metrics %s -> %s, blocked %s, child %s, archive has f6 %s', m0, m1, k0.blocked_by_count, k1.child_count, v->'would_archive' ? f6::text) end);

  -- TC-SB563-10: RPCs
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  set local role authenticated;
  st := pg_temp.try(format($q$select public.cancel_work_item(%L, 'wont_do', 'nope', null, 'x')$q$, f8));
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  v := public.cancel_work_item(f8, 'superseded', null, lower(r1code), pm);
  t := array[st, (v->>'status'), pg_temp.try(format($q$select public.reopen_work_item(%L, 'todo', 'SupaBrain QA')$q$, f8))];
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  r := r || jsonb_build_object('TC-SB563-10', case
         when t[1] like '42501%' and t[2] = 'cancelled' and t[3] = 'ok'
          and (select status = 'todo' and meta->'cancel_history'->0->>'reopened_by' = 'SupaBrain QA' and not meta ? 'reopened_by' from public.work_items where id = f8)
          and not has_function_privilege('anon', 'public.cancel_work_item(uuid,text,text,text,text)', 'execute')
          and not has_function_privilege('anon', 'public.reopen_work_item(uuid,text,text)', 'execute')
          and not exists (select 1 from pg_proc where oid in ('public.cancel_work_item(uuid,text,text,text,text)'::regprocedure,
                                                             'public.reopen_work_item(uuid,text,text)'::regprocedure)
                           and (prosecdef or not proconfig @> array['search_path=""']))
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB563-11: dependants treat cancelled as closed
  r := r || jsonb_build_object('TC-SB563-11', case
         when (select prosrc like '%w.status not in (''done'', ''cancelled'')%' from pg_proc where oid = 'public.crm_steward_scheduled(text)'::regprocedure)
          and (select prosrc like '%v_wi_status NOT IN (''done'',''cancelled'')%'
                      and prosrc like '%CASE WHEN status = ''done'' THEN ''todo'' ELSE status END%'
                 from pg_proc where oid = 'public.sync_school_assignment_to_fam(uuid)'::regprocedure)
         then 'pass' else 'FAIL: dependant sources' end);

  -- TC-SB563-12: backfill (live data)
  r := r || jsonb_build_object('TC-SB563-12', case
         when not exists (select 1 from public.work_items where status = 'done' and meta ? 'closure_reason' and meta->>'closure_reason' !~* '^fixed:')
          and (select count(*) from public.work_items where status = 'cancelled' and cancelled_by = 'Jason'
                 and cancel_note like 'Backfilled from meta.closure_reason:%') = 36
          and (select count(*) from public.work_items where status = 'done' and meta->>'closure_reason' ~* '^fixed:') = 2
          and (select r2.ticket_code from public.work_items w join public.work_items r2 on r2.id = w.cancel_replaced_by where w.ticket_code = 'SB-294') = 'SB-382'
          and (select r2.ticket_code from public.work_items w join public.work_items r2 on r2.id = w.cancel_replaced_by where w.ticket_code = '3A-005') = '3A-001'
          and (select count(*) from public.work_items w join public.work_items r2 on r2.id = w.cancel_replaced_by
                where w.ticket_code in ('SB-130','SB-236','SB-238') and r2.ticket_code = 'SB-257') = 3
         then 'pass' else 'FAIL: backfill' end);

  -- TC-SB563-13: the LCE-041 shape
  st := pg_temp.try(format($q$update public.work_items set status='cancelled', cancel_reason='rejected_by_jason', cancel_note='Jason declined', cancelled_by='Jason' where id=%L$q$, f7));
  r := r || jsonb_build_object('TC-SB563-13', case
         when st = 'ok'
          and (select approval_status = 'rejected' and approved_by = 'Jason' and not meta ? 'approval_gate_exempt' from public.work_items where id = f7)
          and exists (select 1 from public.governance_audit where work_item_id = f7 and decision = 'cancelled' and from_status = 'awaiting_jason')
         then 'pass' else format('FAIL: %s', st) end);

  select count(*) into fails from jsonb_each(r) where value <> '"pass"'::jsonb;
  if fails = 0 then
    raise exception 'CANCEL-SUITE PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'CANCEL-SUITE FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
