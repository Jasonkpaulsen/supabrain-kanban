-- SB-644 (ADR-GOV-001-A2): L0/L1 tickets never wait on Jason. TC-SB644-01, -02, -04.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "GOVERNANCE_AWAITING PASS". Fixtures use ticket codes
-- outside every project's numbering (ZZG-*), have no assignee (no WIP gate) and use
-- approval_status not_required, so only the governance trigger decides. Every step with a side
-- effect runs on its own line, in order: Postgres does not promise to evaluate AND operands in
-- the order written, so a multi-step check inside one CASE can run its steps out of order.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  sb uuid; r jsonb := '{}'::jsonb; fails int; st text;
  t1 uuid; t2 uuid; t3 uuid; legacy uuid; a2 uuid; a3 uuid; a4 uuid; d2 uuid; d3 uuid; d4 uuid; nl uuid;
  s2 uuid; u1 uuid; u2 uuid; rj uuid; rn uuid; s1 text; s3 text;
begin
  select id into sb from public.projects where project_key = 'SB';
  execute $f$create function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'GOV-001 (SB-644)%' then 'SB-644'
                                         when sqlerrm like 'GOV-001%' then 'GOV-001'
                                         when sqlerrm like 'CANCEL-005%only Jason can reopen%' then 'CANCEL-005-jason'
                                         when sqlerrm like 'CANCEL-005%' then 'CANCEL-005'
                                         when sqlerrm like 'Reversal blocked%' then 'REVERSAL' else sqlstate || ': ' || left(sqlerrm, 80) end;
    end $b$$f$;
  execute $f$create function pg_temp.mk(code text, lvl int, st text) returns uuid language sql as $b$
    insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
    values ((select id from public.projects where project_key = 'SB'), '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', code,
            'qa-sb644 ' || code, 'task', st, 'low', 'not_required', lvl) returning id $b$$f$;

  -- TC-SB644-01: entry
  r := r || jsonb_build_object('TC-SB644-01.insert_l0_refused',
         case when pg_temp.t($q$select pg_temp.mk('ZZG-1', 0, 'awaiting_jason')$q$) = 'SB-644' then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB644-01.insert_l1_refused',
         case when pg_temp.t($q$select pg_temp.mk('ZZG-2', 1, 'awaiting_jason')$q$) = 'SB-644' then 'pass' else 'FAIL' end);
  t1 := pg_temp.mk('ZZG-3', 1, 'todo');
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, t1));
  r := r || jsonb_build_object('TC-SB644-01.update_l1_refused',
         case when st = 'SB-644' and (select status from public.work_items where id = t1) = 'todo' then 'pass' else 'FAIL: ' || st end);
  t2 := pg_temp.mk('ZZG-4', 0, 'todo');
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, t2));
  r := r || jsonb_build_object('TC-SB644-01.update_l0_refused', case when st = 'SB-644' then 'pass' else 'FAIL: ' || st end);
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason', authority_level = 2 where id = %L$q$, t1));
  r := r || jsonb_build_object('TC-SB644-01.raise_to_l2_and_enter',
         case when st = 'ok' and (select status || ':' || authority_level from public.work_items where id = t1) = 'awaiting_jason:2' then 'pass' else 'FAIL: ' || st end);
  t3 := pg_temp.mk('ZZG-5', 2, 'todo');
  r := r || jsonb_build_object('TC-SB644-01.l2_enters',
         case when pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, t3)) = 'ok' then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB644-01.l3_l4_null_enter',
         case when pg_temp.t($q$select pg_temp.mk('ZZG-6', 3, 'awaiting_jason')$q$) = 'ok'
                   and pg_temp.t($q$select pg_temp.mk('ZZG-7', 4, 'awaiting_jason')$q$) = 'ok'
                   and pg_temp.t($q$select pg_temp.mk('ZZG-8', null, 'awaiting_jason')$q$) = 'ok' then 'pass' else 'FAIL' end);

  -- TC-SB644-02: exit and downgrade
  -- a legacy L1 ticket already in awaiting_jason (entered before SB-644): only reachable with the
  -- triggers suspended, which this rolled-back transaction does for the one insert
  set local session_replication_role = replica;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
  values (sb, ub, 'ZZG-10', 'qa-sb644 legacy', 'task', 'awaiting_jason', 'low', 'not_required', 1) returning id into legacy;
  set local session_replication_role = origin;
  r := r || jsonb_build_object('TC-SB644-02.legacy_l1_setup',
         case when (select status || ':' || authority_level from public.work_items where id = legacy) = 'awaiting_jason:1' then 'pass' else 'FAIL' end);
  st := pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, legacy));
  r := r || jsonb_build_object('TC-SB644-02.l1_leaves_freely',
         case when st = 'ok' and (select status from public.work_items where id = legacy) = 'todo' then 'pass' else 'FAIL: ' || st end);
  a2 := pg_temp.mk('ZZG-11', 2, 'awaiting_jason');
  a3 := pg_temp.mk('ZZG-12', 3, 'awaiting_jason');
  a4 := pg_temp.mk('ZZG-13', 4, 'awaiting_jason');
  s1 := pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a2));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a3));
  st := pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a4));
  r := r || jsonb_build_object('TC-SB644-02.l2_l3_l4_need_jason',
         case when s1 = 'GOV-001' and s3 = 'GOV-001' and st = 'GOV-001' then 'pass' else 'FAIL: ' || s1 || '/' || s3 || '/' || st end);
  s1 := pg_temp.t(format($q$update public.work_items set status = 'todo', approval_status = 'approved', approved_by = 'Jason Paulsen' where id = %L$q$, a2));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'backlog', approval_status = 'rejected', approved_by = 'Jason Paulsen' where id = %L$q$, a3));
  r := r || jsonb_build_object('TC-SB644-02.l2_l3_leave_on_jason_decision',
         case when s1 = 'ok' and s3 = 'ok' then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  d2 := pg_temp.mk('ZZG-20', 2, 'awaiting_jason');
  d3 := pg_temp.mk('ZZG-21', 3, 'awaiting_jason');
  s1 := pg_temp.t(format($q$update public.work_items set authority_level = 1 where id = %L$q$, d2));
  s3 := pg_temp.t(format($q$update public.work_items set authority_level = null where id = %L$q$, d2));
  st := pg_temp.t(format($q$update public.work_items set authority_level = 2 where id = %L$q$, d3));
  r := r || jsonb_build_object('TC-SB644-02.no_downgrade_in_queue',
         case when s1 = 'SB-644' and s3 = 'SB-644' and st = 'SB-644' and (select authority_level from public.work_items where id = d2) = 2
              then 'pass' else 'FAIL: ' || s1 || '/' || s3 || '/' || st end);
  s1 := pg_temp.t(format($q$update public.work_items set status = 'todo', authority_level = 1 where id = %L$q$, d2));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'todo', authority_level = null where id = %L$q$, d2));
  r := r || jsonb_build_object('TC-SB644-02.no_downgrade_on_the_way_out',
         case when s1 = 'SB-644' and s3 = 'SB-644' and (select status from public.work_items where id = d2) = 'awaiting_jason'
              then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  s1 := pg_temp.t(format($q$update public.work_items set authority_level = 1, approval_status = 'approved', approved_by = 'Jason Paulsen' where id = %L$q$, d2));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'todo', authority_level = 1, approval_status = 'approved', approved_by = 'Jason Paulsen' where id = %L$q$, d2));
  r := r || jsonb_build_object('TC-SB644-02.jason_downgrade_moves_it_out',
         case when s1 = 'SB-644' and s3 = 'ok' and (select status || ':' || authority_level from public.work_items where id = d2) = 'todo:1'
              then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  d4 := pg_temp.mk('ZZG-22', 2, 'todo');
  s1 := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, d4));
  s3 := pg_temp.t(format($q$update public.work_items set authority_level = 3 where id = %L$q$, d4));
  r := r || jsonb_build_object('TC-SB644-02.raise_in_queue_allowed',
         case when s1 = 'ok' and s3 = 'ok' and (select status || ':' || authority_level from public.work_items where id = d4) = 'awaiting_jason:3'
              then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  nl := pg_temp.mk('ZZG-23', null, 'awaiting_jason');
  r := r || jsonb_build_object('TC-SB644-02.null_level_unchanged',
         case when pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, nl)) = 'ok' then 'pass' else 'FAIL' end);

  -- TC-SB644-04 (verification of 20261026031138)
  st := pg_temp.t(format($q$update public.work_items set authority_level = 1 where id = %L$q$, pg_temp.mk('ZZG-30', null, 'awaiting_jason')));
  r := r || jsonb_build_object('TC-SB644-04.no_classifying_to_l1_in_queue', case when st = 'SB-644' then 'pass' else 'FAIL: ' || st end);
  s2 := pg_temp.mk('ZZG-31', 2, 'todo');
  update public.work_items set approval_status = 'approved', approved_by = 'Jason Paulsen', approved_at = now() where id = s2;
  update public.work_items set status = 'awaiting_jason' where id = s2;
  s1 := (select (approved_by is null and approved_at is null and approval_status = 'pending')::text from public.work_items where id = s2);
  s3 := pg_temp.t(format($q$update public.work_items set status = 'todo', approval_status = 'approved' where id = %L$q$, s2));
  r := r || jsonb_build_object('TC-SB644-04.entry_clears_old_approver',
         case when s1 = 'true' and s3 = 'GOV-001' then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  u1 := pg_temp.mk('ZZG-32', 1, 'todo');
  update public.work_items set approval_status = 'approved', approved_by = 'Jason Paulsen' where id = u1;
  st := pg_temp.t(format($q$update public.work_items set approval_status = 'pending', meta = coalesce(meta, '{}') || '{"reversal_actor":"Jason Paulsen"}' where id = %L$q$, u1));
  r := r || jsonb_build_object('TC-SB644-04.l1_unapprove_in_place',
         case when st = 'ok' and (select status || ':' || approval_status || ':' || (meta->'approval_history'->-1->>'gesture') from public.work_items where id = u1) = 'todo:pending:un_approve'
              then 'pass' else 'FAIL: ' || st end);
  u2 := pg_temp.mk('ZZG-33', 2, 'todo');
  update public.work_items set approval_status = 'approved', approved_by = 'Jason Paulsen' where id = u2;
  st := pg_temp.t(format($q$update public.work_items set approval_status = 'pending' where id = %L$q$, u2));
  r := r || jsonb_build_object('TC-SB644-04.l2_unapprove_in_place_still_blocked', case when st = 'REVERSAL' then 'pass' else 'FAIL: ' || st end);
  rj := pg_temp.mk('ZZG-34', 1, 'todo');
  update public.work_items set status = 'cancelled', cancel_reason = 'rejected_by_jason', cancel_note = 'qa: not wanted', cancelled_by = 'Jason' where id = rj;
  s1 := pg_temp.t(format($q$update public.work_items set status = 'backlog', meta = coalesce(meta, '{}') || '{"reopened_by":"Family PM"}' where id = %L$q$, rj));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'backlog', meta = coalesce(meta, '{}') || '{"reopened_by":"Jason"}' where id = %L$q$, rj));
  r := r || jsonb_build_object('TC-SB644-04.l1_rejected_reopen_needs_jason',
         case when s1 = 'CANCEL-005-jason' and s3 = 'ok' and (select status from public.work_items where id = rj) = 'backlog'
              then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);
  rn := pg_temp.mk('ZZG-35', null, 'todo');
  update public.work_items set status = 'cancelled', cancel_reason = 'rejected_by_jason', cancel_note = 'qa: not wanted', cancelled_by = 'Jason' where id = rn;
  s1 := pg_temp.t(format($q$update public.work_items set status = 'backlog', meta = coalesce(meta, '{}') || '{"reopened_by":"Jason"}' where id = %L$q$, rn));
  s3 := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason', meta = coalesce(meta, '{}') || '{"reopened_by":"Jason"}' where id = %L$q$, rn));
  r := r || jsonb_build_object('TC-SB644-04.other_rejected_reopens_unchanged',
         case when s1 = 'CANCEL-005' and s3 = 'ok' then 'pass' else 'FAIL: ' || s1 || '/' || s3 end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'GOVERNANCE_AWAITING PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'GOVERNANCE_AWAITING FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
