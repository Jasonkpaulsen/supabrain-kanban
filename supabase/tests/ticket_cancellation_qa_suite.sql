-- SB-566 independent QA of ticket cancellation (ADR-FLOW-004). TC-SB566-1..9.
-- Written separately from the build suite (ticket_cancellation_suite.sql) with its own fixtures.
-- One transaction that always ends in an exception, so nothing it writes is kept.
-- Marker: "CANCEL-QA PASS (9 checks)".
do $qa$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner (Jason)
  dev constant text := 'Supabase Platform Engineer';
  r jsonb := '{}'::jsonb;
  sb uuid; pe uuid;
  ids uuid[] := '{}'; st text; t text[]; x record;
  q0 int; q1 int; m0 record; m1 record;
  a0 timestamptz; ms numeric; ms_cx numeric; i int; aud uuid; fm jsonb;
  s_todo uuid; s_prog uuid; s_rev uuid; s_blk uuid; s_hold uuid; s_aw uuid;
  l0 uuid; l2 uuid; l3 uuid; l4 uuid; l4aw uuid; rej uuid; lat uuid;
  fails int;
begin
  select id into sb from public.projects where project_key = 'SB';
  select id into pe from public.agents where name = 'SupaBrain Process Engineer' limit 1;
  execute $f$create function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return coalesce(substring(sqlerrm from '^(CANCEL-[0-9]+|GOV-[0-9]+|Approval required|QA required)'), sqlstate);
    end $b$$f$;
  execute $f$create function pg_temp.cx(id uuid, actor text, reason text default 'wont_do') returns text language sql as $b$
    select pg_temp.t(format('update public.work_items set status=''cancelled'', cancel_reason=%L, cancel_note=''QA: retire it'', cancelled_by=%L where id=%L', reason, actor, id))
  $b$$f$;

  -- fixtures: one per starting state (L1, no assignee so no WIP gate re-parks them)
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-1', 'qa cancel from todo', 'task', 'todo', 'low', 'not_required', 1) returning id into s_todo;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-2', 'qa cancel from in_progress', 'task', 'in_progress', 'low', 'not_required', 1) returning id into s_prog;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-3', 'qa cancel from review', 'task', 'review', 'low', 'not_required', 1) returning id into s_rev;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-4', 'qa cancel from blocked', 'task', 'blocked', 'low', 'not_required', 1) returning id into s_blk;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-5', 'qa cancel from on_hold', 'task', 'on_hold', 'low', 'not_required', 1) returning id into s_hold;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-6', 'qa cancel from awaiting_jason', 'task', 'awaiting_jason', 'low', 'pending', 1) returning id into s_aw;
  -- authority matrix
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-10', 'qa L0', 'task', 'todo', 'low', 'not_required', 0) returning id into l0;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-12', 'qa L2', 'task', 'todo', 'low', 'not_required', 2) returning id into l2;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-13', 'qa L3', 'task', 'backlog', 'low', 'pending', 3) returning id into l3;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-14', 'qa L4', 'task', 'backlog', 'low', 'pending', 4) returning id into l4;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-15', 'qa L4 awaiting', 'task', 'awaiting_jason', 'low', 'pending', 4) returning id into l4aw;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-16', 'qa rejected task', 'task', 'todo', 'low', 'rejected', 1) returning id into rej;
  insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level) values
    (sb, ub, 'ZZQ-17', 'qa latency', 'task', 'todo', 'low', 'not_required', 1) returning id into lat;

  select total_items, done_items, cancelled_items into m0 from public.jarvis_ops_metrics where user_id = ub;
  select count(*) into q0 from public.governance_audit where decision = 'cancelled';

  -- TC-SB566-1: from every state
  t := array[pg_temp.cx(s_todo, dev), pg_temp.cx(s_prog, dev), pg_temp.cx(s_rev, dev), pg_temp.cx(s_blk, dev),
             pg_temp.cx(s_hold, dev), pg_temp.cx(s_aw, dev), pg_temp.cx(s_aw, 'Jason')];
  r := r || jsonb_build_object('TC-SB566-1', case
         when t = array['ok','ok','ok','ok','ok','CANCEL-003','ok']
          and (select count(*) from public.work_items where id in (s_todo,s_prog,s_rev,s_blk,s_hold,s_aw) and status = 'cancelled') = 6
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB566-2: authority matrix, including L4
  t := array[pg_temp.cx(l0, dev), pg_temp.cx(l2, dev), pg_temp.cx(l2, 'Family PM'),
             pg_temp.cx(l3, 'JARVIS — Master Orchestrator'), pg_temp.cx(l3, 'Jason'),
             pg_temp.cx(l4, 'SupaBrain Operations PM'), pg_temp.cx(l4, 'JARVIS — Master Orchestrator'), pg_temp.cx(l4, 'Jason'),
             pg_temp.cx(l4aw, 'JARVIS — Master Orchestrator'), pg_temp.cx(l4aw, 'Jason')];
  r := r || jsonb_build_object('TC-SB566-2', case
         when t = array['ok','CANCEL-003','ok','CANCEL-003','ok','CANCEL-003','CANCEL-003','ok','CANCEL-003','ok']
          and (select approval_status = 'rejected' and approved_by = 'Jason' from public.work_items where id = l4aw)
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB566-3: no gate bypass anywhere; the done gate still refuses a rejected ticket
  st := pg_temp.t(format('update public.work_items set status=''done'' where id=%L', rej));
  t := array[st, pg_temp.cx(rej, dev)];
  r := r || jsonb_build_object('TC-SB566-3', case
         when t[1] <> 'ok' and t[2] = 'ok'
          -- Rows cancelled through the new path never carry a bypass flag. (The 9 backfilled
          -- rows that do were given those flags when they were mis-closed as done before
          -- SB-563; that workaround is exactly what this epic retires.)
          and not exists (select 1 from public.work_items where status = 'cancelled'
                           and cancel_note not like 'Backfilled from meta.closure_reason:%'
                           and (meta ? 'approval_gate_exempt' or meta ? 'qa_gate_exempt' or meta ? 'review_gate_exempt'))
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB566-4: never completed_at, never a QA verdict (in_progress fixture had no test cases)
  r := r || jsonb_build_object('TC-SB566-4', case
         when not exists (select 1 from public.work_items where id in (s_todo,s_prog,s_rev,s_blk,s_hold,s_aw,l0,l2,l3,l4,l4aw,rej)
                           and (completed_at is not null or qa_status is not null))
         then 'pass' else 'FAIL: completed_at or qa_status set' end);

  -- TC-SB566-5: one audit row per cancellation, with actor and reason
  select count(*) into q1 from public.governance_audit where decision = 'cancelled';
  r := r || jsonb_build_object('TC-SB566-5', case
         when q1 - q0 = 12
          and not exists (select 1 from public.work_items w where w.id in (s_todo,s_prog,s_rev,s_blk,s_hold,s_aw,l0,l2,l3,l4,l4aw,rej)
                           and not exists (select 1 from public.governance_audit g where g.work_item_id = w.id and g.decision = 'cancelled'
                                             and g.decided_by = w.cancelled_by and g.notes like '%reason=' || w.cancel_reason || '%'))
         then 'pass' else format('FAIL: %s new audit rows', q1 - q0) end);

  -- TC-SB566-6: metrics and the daily audit ignore cancelled work
  select total_items, done_items, cancelled_items into m1 from public.jarvis_ops_metrics where user_id = ub;
  begin
    aud := public.generate_daily_audit(ub, sb, current_date, pe);
    select to_jsonb(pa) into fm from public.process_audits pa where pa.id = aud;
  exception when others then fm := jsonb_build_object('error', sqlerrm);
  end;
  r := r || jsonb_build_object('TC-SB566-6', case
         when m1.total_items = m0.total_items - 12 and m1.done_items = m0.done_items and m1.cancelled_items = m0.cancelled_items + 12
          and fm->'flow_metrics' ? 'cancelled'
          and (fm->'flow_metrics'->>'cancelled')::int >= 12
         then 'pass' else format('FAIL: %s -> %s; flow %s', m0, m1, fm->'flow_metrics') end);

  -- TC-SB566-7: reopen path
  t := array[pg_temp.t(format('update public.work_items set status=''backlog'' where id=%L', l4)),
             pg_temp.t(format('update public.work_items set status=''awaiting_jason'' where id=%L', l4)),
             pg_temp.t(format('update public.work_items set status=''todo'' where id=%L', l0))];
  r := r || jsonb_build_object('TC-SB566-7', case
         when t = array['CANCEL-005','ok','ok']
          and (select status = 'awaiting_jason' and approval_status = 'pending' and jsonb_array_length(meta->'cancel_history') = 1 from public.work_items where id = l4)
          and exists (select 1 from public.governance_audit where work_item_id = l0 and decision = 'reopened')
         then 'pass' else format('FAIL: %s', t) end);

  -- TC-SB566-8: write latency on the 20+-trigger UPDATE path
  a0 := clock_timestamp();
  for i in 1..20 loop
    update public.work_items set priority = case when i % 2 = 0 then 'low' else 'medium' end where id = lat;
  end loop;
  ms := extract(epoch from clock_timestamp() - a0) * 1000 / 20;
  a0 := clock_timestamp();
  perform pg_temp.cx(lat, dev);
  perform pg_temp.t(format('update public.work_items set status=''todo'' where id=%L', lat));
  ms_cx := extract(epoch from clock_timestamp() - a0) * 1000 / 2;
  r := r || jsonb_build_object('TC-SB566-8', case when ms < 50 and ms_cx < 100 then 'pass'
         else format('FAIL: %s ms per update, %s ms per cancel/reopen', round(ms, 1), round(ms_cx, 1)) end,
         'TC-SB566-8.ms', round(ms, 2), 'TC-SB566-8.ms_cancel', round(ms_cx, 2));

  -- TC-SB566-9: the live regression case (LCE-041, LCE-070)
  r := r || jsonb_build_object('TC-SB566-9', case
         when (select count(*) from public.work_items w
                where w.ticket_code in ('LCE-041','LCE-070') and w.status = 'cancelled' and w.cancelled_by = 'Jason'
                  and w.approval_status = 'rejected' and w.approved_by = 'Jason'
                  and not (w.meta ? 'approval_gate_exempt')
                  and exists (select 1 from public.governance_audit g where g.work_item_id = w.id and g.decision = 'cancelled'
                                and g.from_status = 'awaiting_jason')) = 2
         then 'pass' else 'FAIL: LCE-041/070' end);

  select count(*) into fails from jsonb_each(r) where key not like '%.%' and value <> '"pass"'::jsonb;
  if fails = 0 then
    raise exception 'CANCEL-QA PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.%'), r::text;
  else
    raise exception 'CANCEL-QA FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.%'), r::text;
  end if;
end $qa$;
