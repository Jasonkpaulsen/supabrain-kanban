-- SB-644 (ADR-GOV-001-A2): L0/L1 tickets never wait on Jason. TC-SB644-01, TC-SB644-02.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "GOVERNANCE_AWAITING PASS". Fixtures use ticket codes
-- outside every project's numbering (ZZG-*), have no assignee (no WIP gate) and use
-- approval_status not_required, so only the governance trigger decides.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  sb uuid; r jsonb := '{}'::jsonb; fails int; st text;
  t1 uuid; t2 uuid; t3 uuid; legacy uuid; a2 uuid; a3 uuid; a4 uuid; d2 uuid; d3 uuid; d4 uuid; nl uuid;
begin
  select id into sb from public.projects where project_key = 'SB';
  execute $f$create function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'GOV-001 (SB-644)%' then 'SB-644'
                                         when sqlerrm like 'GOV-001%' then 'GOV-001' else sqlstate || ': ' || left(sqlerrm, 80) end;
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
  -- a legacy L1 ticket already in awaiting_jason (entered before SB-644): classify a NULL-level one as L1 in place
  legacy := pg_temp.mk('ZZG-10', null, 'awaiting_jason');
  st := pg_temp.t(format($q$update public.work_items set authority_level = 1 where id = %L$q$, legacy));
  r := r || jsonb_build_object('TC-SB644-02.legacy_l1_setup', case when st = 'ok' then 'pass' else 'FAIL: ' || st end);
  st := pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, legacy));
  r := r || jsonb_build_object('TC-SB644-02.l1_leaves_freely',
         case when st = 'ok' and (select status from public.work_items where id = legacy) = 'todo' then 'pass' else 'FAIL: ' || st end);
  a2 := pg_temp.mk('ZZG-11', 2, 'awaiting_jason');
  a3 := pg_temp.mk('ZZG-12', 3, 'awaiting_jason');
  a4 := pg_temp.mk('ZZG-13', 4, 'awaiting_jason');
  r := r || jsonb_build_object('TC-SB644-02.l2_l3_l4_need_jason',
         case when pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a2)) = 'GOV-001'
                   and pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a3)) = 'GOV-001'
                   and pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, a4)) = 'GOV-001'
              then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB644-02.l2_l3_leave_on_jason_decision',
         case when pg_temp.t(format($q$update public.work_items set status = 'todo', approval_status = 'approved', approved_by = 'Jason Paulsen' where id = %L$q$, a2)) = 'ok'
                   and pg_temp.t(format($q$update public.work_items set status = 'backlog', approval_status = 'rejected', approved_by = 'Jason Paulsen' where id = %L$q$, a3)) = 'ok'
              then 'pass' else 'FAIL' end);
  d2 := pg_temp.mk('ZZG-20', 2, 'awaiting_jason');
  d3 := pg_temp.mk('ZZG-21', 3, 'awaiting_jason');
  r := r || jsonb_build_object('TC-SB644-02.no_downgrade_in_queue',
         case when pg_temp.t(format($q$update public.work_items set authority_level = 1 where id = %L$q$, d2)) = 'SB-644'
                   and pg_temp.t(format($q$update public.work_items set authority_level = null where id = %L$q$, d2)) = 'SB-644'
                   and pg_temp.t(format($q$update public.work_items set authority_level = 2 where id = %L$q$, d3)) = 'SB-644'
                   and (select authority_level from public.work_items where id = d2) = 2
              then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB644-02.no_downgrade_on_the_way_out',
         case when pg_temp.t(format($q$update public.work_items set status = 'todo', authority_level = 1 where id = %L$q$, d2)) = 'SB-644'
                   and pg_temp.t(format($q$update public.work_items set status = 'todo', authority_level = null where id = %L$q$, d2)) = 'SB-644'
                   and (select status from public.work_items where id = d2) = 'awaiting_jason'
              then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB644-02.jason_may_downgrade',
         case when pg_temp.t(format($q$update public.work_items set authority_level = 1, approval_status = 'approved', approved_by = 'Jason Paulsen' where id = %L$q$, d2)) = 'ok'
              then 'pass' else 'FAIL' end);
  d4 := pg_temp.mk('ZZG-22', 2, 'todo');
  r := r || jsonb_build_object('TC-SB644-02.raise_in_queue_allowed',
         case when pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, d4)) = 'ok'
                   and pg_temp.t(format($q$update public.work_items set authority_level = 3 where id = %L$q$, d4)) = 'ok'
              then 'pass' else 'FAIL' end);
  nl := pg_temp.mk('ZZG-23', null, 'awaiting_jason');
  r := r || jsonb_build_object('TC-SB644-02.null_level_unchanged',
         case when pg_temp.t(format($q$update public.work_items set status = 'todo' where id = %L$q$, nl)) = 'ok' then 'pass' else 'FAIL' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'GOVERNANCE_AWAITING PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'GOVERNANCE_AWAITING FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
