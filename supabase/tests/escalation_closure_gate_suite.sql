-- Escalation closure gate suite: TC-SB526-1..8 (SB-526; ADR-FLOW-005 D8).
--
-- Run as postgres. One transaction that always ends by raising, so nothing it creates or
-- inserts survives. Fixtures are SB-project chores owned by the owner, with ticket codes
-- outside every project's numbering (ZZE-n). The gate ships in warn mode, so each held close
-- is asserted to succeed with meta.escalation_closure.verdict stamped; TC-1, TC-3 and TC-6 are
-- then repeated with escalation_gate_mode replaced to return 'enforce' inside a rolled-back
-- sub-block, asserting sqlstate P0001 and the message prefix.
-- TC-SB526-8 / 8e pin the pkg-2 verifier fixes: meta and title writes cannot take an escalation
-- out of scope, repoint its upstream, or rewrite / remove the trigger-owned snapshot and verdict;
-- a row without a snapshot is pinned by a legacy snapshot on its first write.
-- TC-SB526-2 and TC-7 pin escalation_upstream_id as SECURITY INVOKER (no cross-owner lookup).
-- Pass = the raised message starts with "ESCALATION_CLOSURE_GATE PASS". The message carries
-- only counts, ticket codes, verdicts and sqlstates, never titles or free text.

do $suite$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  pj  constant uuid := 'a07a7f3d-722f-468f-81fa-84e2c5fba704';   -- SB project
  qa  constant text := 'SupaBrain QA';
  rb  constant text := '__sb526_rollback__';
  r jsonb := '{}'::jsonb;
  u1 uuid; e1 uuid; u2a uuid; u2b uuid; u2c uuid; u2d uuid; u2e uuid; e2a uuid; e2b uuid; e2c uuid; e2d uuid; e2e uuid; e2f uuid;
  u3 uuid; e3 uuid; u4 uuid; e4 uuid; b4 uuid; u4b uuid; e4b uuid; b4b uuid; u4c uuid; e4c uuid;
  u5 uuid; e5 uuid; e5d uuid; e5s uuid; u6 uuid; e6 uuid; u7 uuid; e7 uuid;
  u8 uuid; d8 uuid; e8a uuid; e8b uuid; e8d uuid; e8e uuid; u8e uuid; f8 uuid; g8 uuid; st2 text; msg2 text;
  t text[]; n int; k int; fails int; st text; msg text; v jsonb; xid uuid;
begin
  execute $f$create function pg_temp.fx(p_code text, p_title text, p_status text, p_assignee text, p_meta jsonb,
                                         p_created timestamptz default now())
    returns uuid language plpgsql as $b$
    declare v uuid;
    begin
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status,
                                     assignee, meta, created_at)
      values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', p_code, p_title, 'chore',
              p_status, 'high', 'not_required', p_assignee, coalesce(p_meta, '{}'::jsonb), p_created)
      returning id into v;
      return v;
    end $b$$f$;

  -- ------------------------------------------------ TC-SB526-1: ESCALATION-001 (warn: close succeeds, verdict stamped)
  begin
    u1 := pg_temp.fx('ZZE-1', 'qa-sb526 upstream 1', 'blocked', null, null);
    e1 := pg_temp.fx('ZZE-2', 'ESCALATION: qa-sb526 escalation 1', 'todo', null, '{"upstream_ticket":"ZZE-1"}');
    update public.work_items set assignee = qa where id = u1;          -- differs from the snapshot; still no evidence
    update public.work_items set status = 'done' where id = e1;
    select array[status, meta->'escalation_closure'->>'verdict', meta->'escalation_closure'->>'upstream',
                 meta->'escalation_snapshot'->>'status']
      into t from public.work_items where id = e1;
    r := r || jsonb_build_object('TC-SB526-1', case when t = array['done','ESCALATION-001','ZZE-1','blocked'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB526-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-2: upstream resolution and scope
  begin
    u2a := pg_temp.fx('ZZE-10', 'qa-sb526 upstream 2a', 'blocked', qa, null);
    u2b := pg_temp.fx('ZZE-11', 'qa-sb526 upstream 2b', 'blocked', qa, null);
    u2c := pg_temp.fx('ZZE-12', 'qa-sb526 upstream 2c', 'blocked', qa, null);
    k := 0;
    if public.escalation_upstream_id('ESCALATION: ZZE-12', '{"upstream_ticket":"zze-10","escalates":"ZZE-11"}', ub, null) = u2a then k := k + 1; end if;
    if public.escalation_upstream_id('ESCALATION: ZZE-12', '{"upstream_ticket":"ZZQ-99999","escalates":"ZZE-11"}', ub, null) = u2b then k := k + 1; end if;
    if public.escalation_upstream_id('ESCALATION: stuck ZZE-12 and ZZE-10', '{}', ub, null) = u2c then k := k + 1; end if;
    if public.escalation_upstream_id('ESCALATION: ZZE-12', '{}', ub, u2c) is null then k := k + 1; end if;           -- never itself
    if public.escalation_upstream_id('ESCALATION: ZZE-12', '{}', gen_random_uuid(), null) is null then k := k + 1; end if; -- other owner
    if public.escalation_upstream_id('ESCALATION: nothing here', '{}', ub, null) is null then k := k + 1; end if;
    -- SECURITY INVOKER: the owner session resolves its own code but never another owner's
    select w.ticket_code, w.user_id into msg, xid
      from public.work_items w where w.user_id <> ub and w.ticket_code ~ '^[A-Z0-9]+-[0-9]+$' order by w.created_at limit 1;
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    if msg is null or public.escalation_upstream_id(null, jsonb_build_object('upstream_ticket', msg), xid, null) is null then k := k + 1; end if;
    if public.escalation_upstream_id('ESCALATION: ZZE-12', '{}', ub, null) = u2c then k := k + 1; end if;
    reset role;
    perform set_config('request.jwt.claims', '{}', true);
    -- handoff issue type: out of scope (no snapshot, no verdict)
    e2a := pg_temp.fx('ZZE-13', 'ESCALATION: qa-sb526 handoff', 'todo', null, '{"issue_type":"handoff_gap","upstream_ticket":"ZZE-10"}');
    update public.work_items set status = 'done' where id = e2a;
    -- unresolvable upstream: out of scope
    e2b := pg_temp.fx('ZZE-14', 'ESCALATION: qa-sb526 unresolvable', 'todo', null, '{"upstream_ticket":"ZZQ-99999"}');
    update public.work_items set status = 'done' where id = e2b;
    -- issue_type alone qualifies (no ESCALATION title)
    e2c := pg_temp.fx('ZZE-15', 'qa-sb526 issue type only', 'todo', null, '{"issue_type":"stale_critical_blocker","upstream_ticket":"ZZE-11"}');
    -- upstream resolved before the close
    u2d := pg_temp.fx('ZZE-16', 'qa-sb526 upstream 2d', 'blocked', qa, null);
    e2d := pg_temp.fx('ZZE-17', 'ESCALATION: qa-sb526 resolved ZZE-16', 'todo', null, null);
    update public.work_items set status = 'done' where id = u2d;
    update public.work_items set status = 'done' where id = e2d;
    -- upstream moved out of the escalated status (blocked -> todo)
    u2e := pg_temp.fx('ZZE-18', 'qa-sb526 upstream 2e', 'blocked', qa, null);
    e2e := pg_temp.fx('ZZE-19', 'ESCALATION: qa-sb526 moved', 'todo', null, '{"escalates":"ZZE-18"}');
    update public.work_items set status = 'todo' where id = u2e;
    update public.work_items set status = 'done' where id = e2e;
    select array[
      (select (meta ? 'escalation_snapshot')::text || '/' || (meta ? 'escalation_closure')::text || '/' || status from public.work_items where id = e2a),
      (select (meta ? 'escalation_snapshot')::text || '/' || (meta ? 'escalation_closure')::text || '/' || status from public.work_items where id = e2b),
      (select meta->'escalation_snapshot'->>'upstream' from public.work_items where id = e2c),
      (select (meta ? 'escalation_closure')::text || '/' || status from public.work_items where id = e2d),
      (select (meta ? 'escalation_closure')::text || '/' || status from public.work_items where id = e2e)]
      into t;
    r := r || jsonb_build_object('TC-SB526-2', case
           when k = 8 and t = array['false/false/done','false/false/done','ZZE-11','false/done','false/done'] then 'pass'
           else format('FAIL: resolution %s of 8, scope %s', k, t) end);
  exception when others then
    reset role;
    r := r || jsonb_build_object('TC-SB526-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-3: ESCALATION-002 (nothing changed since the snapshot)
  begin
    u3 := pg_temp.fx('ZZE-20', 'qa-sb526 upstream 3', 'blocked', qa, null);
    e3 := pg_temp.fx('ZZE-21', 'ESCALATION: qa-sb526 escalation 3', 'todo', null, '{"upstream_ticket":"ZZE-20"}', now() - interval '1 hour');
    insert into public.work_item_comments (work_item_id, user_id, body) values (u3, ub, 'qa-sb526 re-check note');
    update public.work_items set status = 'done' where id = e3;
    select array[status, meta->'escalation_closure'->>'verdict'] into t from public.work_items where id = e3;
    r := r || jsonb_build_object('TC-SB526-3', case when t = array['done','ESCALATION-002'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB526-3', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-4: re-verification evidence lets the close through
  begin
    -- 4a: comment after the escalation, owned upstream, one open owned blocker
    u4 := pg_temp.fx('ZZE-30', 'qa-sb526 upstream 4', 'blocked', qa, null);
    e4 := pg_temp.fx('ZZE-31', 'ESCALATION: qa-sb526 escalation 4', 'todo', null, '{"upstream_ticket":"ZZE-30"}', now() - interval '1 hour');
    b4 := pg_temp.fx('ZZE-32', 'qa-sb526 blocker 4', 'todo', qa, null);
    insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, b4, u4, 'blocks');
    insert into public.work_item_comments (work_item_id, user_id, body) values (u4, ub, 'qa-sb526 re-verified');
    update public.work_items set status = 'done' where id = e4;
    -- 4b: same, but the blocker is unowned (linked as upstream blocked_by blocker)
    u4b := pg_temp.fx('ZZE-33', 'qa-sb526 upstream 4b', 'blocked', qa, null);
    e4b := pg_temp.fx('ZZE-34', 'ESCALATION: qa-sb526 escalation 4b', 'todo', null, '{"upstream_ticket":"ZZE-33"}', now() - interval '1 hour');
    b4b := pg_temp.fx('ZZE-35', 'qa-sb526 blocker 4b', 'todo', null, null);
    insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, u4b, b4b, 'blocked_by');
    insert into public.work_item_comments (work_item_id, user_id, body) values (u4b, ub, 'qa-sb526 re-verified');
    update public.work_items set status = 'done' where id = e4b;
    -- 4c: the only open blocker is the escalation itself
    u4c := pg_temp.fx('ZZE-36', 'qa-sb526 upstream 4c', 'blocked', qa, null);
    e4c := pg_temp.fx('ZZE-37', 'ESCALATION: qa-sb526 escalation 4c', 'todo', qa, '{"upstream_ticket":"ZZE-36"}', now() - interval '1 hour');
    insert into public.work_item_links (user_id, from_item_id, to_item_id, link_type) values (ub, e4c, u4c, 'blocks');
    insert into public.work_item_comments (work_item_id, user_id, body) values (u4c, ub, 'qa-sb526 re-verified');
    update public.work_items set status = 'done' where id = e4c;
    select array[
      (select (meta ? 'escalation_closure')::text || '/' || status from public.work_items where id = e4),
      (select coalesce(meta->'escalation_closure'->>'verdict', 'none') from public.work_items where id = e4b),
      (select coalesce(meta->'escalation_closure'->>'verdict', 'none') from public.work_items where id = e4c),
      array_to_string(public.escalation_open_blockers(u4), ',')]
      into t;
    r := r || jsonb_build_object('TC-SB526-4', case
           when t = array['false/done','ESCALATION-001','ESCALATION-001','ZZE-32'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB526-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-5: no exempt flag honoured; cancel duplicate is the escape hatch
  begin
    u5 := pg_temp.fx('ZZE-40', 'qa-sb526 upstream 5', 'blocked', null, null);
    e5 := pg_temp.fx('ZZE-41', 'ESCALATION: qa-sb526 escalation 5', 'todo', null,
                     '{"upstream_ticket":"ZZE-40","escalation_exempt":true,"qa_gate_exempt":true,"review_gate_exempt":true}');
    e5s := pg_temp.fx('ZZE-42', 'ESCALATION: qa-sb526 survivor 5', 'todo', null, '{"upstream_ticket":"ZZE-40"}');
    e5d := pg_temp.fx('ZZE-43', 'ESCALATION: qa-sb526 duplicate 5', 'todo', null, '{"upstream_ticket":"ZZE-40"}');
    update public.work_items set assignee = qa where id = u5;
    update public.work_items set status = 'done' where id = e5;
    -- 5d: cancel_work_item as the owner (ticket_cancellation_suite.sql pattern)
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    st := 'ok';
    begin
      v := public.cancel_work_item(e5d, 'duplicate', 'qa-sb526 duplicate of the survivor', 'ZZE-42', qa);
    exception when others then st := 'blocked: ' || sqlstate;
    end;
    reset role;
    perform set_config('request.jwt.claims', '{}', true);
    select array[
      (select status || '/' || coalesce(meta->'escalation_closure'->>'verdict', 'none') from public.work_items where id = e5),
      st,
      (select status || '/' || coalesce(cancel_reason, 'none') || '/' || (meta ? 'escalation_closure')::text
         || '/' || (cancel_replaced_by = e5s)::text from public.work_items where id = e5d)]
      into t;
    r := r || jsonb_build_object('TC-SB526-5', case
           when t = array['done/ESCALATION-001','ok','cancelled/duplicate/false/true'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    reset role;
    r := r || jsonb_build_object('TC-SB526-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-6: insert as done is gated too
  begin
    u6 := pg_temp.fx('ZZE-50', 'qa-sb526 upstream 6', 'blocked', null, null);
    e6 := pg_temp.fx('ZZE-51', 'ESCALATION: qa-sb526 escalation 6', 'done', null, '{"upstream_ticket":"ZZE-50"}');
    select array[status, meta->'escalation_closure'->>'verdict', (meta ? 'escalation_snapshot')::text]
      into t from public.work_items where id = e6;
    r := r || jsonb_build_object('TC-SB526-6', case when t = array['done','ESCALATION-001','true'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB526-6', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-7: audit view and posture
  begin
    u7 := pg_temp.fx('ZZE-60', 'qa-sb526 upstream 7', 'blocked', null, null);
    e7 := pg_temp.fx('ZZE-61', 'ESCALATION: qa-sb526 open escalation 7', 'todo', null, '{"upstream_ticket":"ZZE-60"}');
    t := array[
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'SB-525' and row_kind = 'escalation'), 'none'),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'SB-426' and row_kind = 'escalation'), 'none'),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'ZZE-61' and row_kind = 'escalation'), 'none'),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'ZZE-2' and row_kind = 'escalation'), 'none'),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'ZZE-31' and row_kind = 'escalation'), 'none'),
      coalesce((select string_agg(ticket_code, ',' order by ticket_code) from public.vw_escalation_closure_audit
                 where ticket_code in ('ZZE-13', 'ZZE-14', 'ZZE-43')), 'none')];
    -- SB-336 is a governance violation while it stays blocked > 14 days behind done SB-426
    if exists (select 1 from public.work_items where ticket_code = 'SB-336' and status = 'blocked' and updated_at < now() - interval '14 days') then
      t := t || coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'SB-336' and row_kind = 'upstream'), 'none');
    else
      t := t || 'governance_violation'::text;
    end if;
    k := 0;
    if exists (select 1 from pg_class where oid = 'public.vw_escalation_closure_audit'::regclass
                 and reloptions @> array['security_invoker=true']) then k := k + 1; end if;
    if exists (select 1 from pg_trigger where tgname = 'trg_escalation_closure'
                 and tgrelid = 'public.work_items'::regclass and tgenabled = 'O') then k := k + 1; end if;
    select string_agg(tgname, ',' order by tgname collate "C") into msg
      from pg_trigger where tgrelid = 'public.work_items'::regclass
       and tgname in ('trg_done_gate', 'trg_escalation_closure', 'trg_qa_gate');
    if msg = 'trg_done_gate,trg_escalation_closure,trg_qa_gate' then k := k + 1; end if;
    if not (select prosecdef from pg_proc where oid = 'public.escalation_upstream_id(text,jsonb,uuid,uuid)'::regprocedure)
       and not has_function_privilege('anon', 'public.escalation_upstream_id(text,jsonb,uuid,uuid)', 'execute') then k := k + 1; end if;
    if public.escalation_gate_mode('SB-526') = 'warn' then k := k + 1; end if;
    if not has_table_privilege('anon', 'public.vw_escalation_closure_audit', 'select') then k := k + 1; end if;
    if (select array_agg(a.attname::text order by a.attname)
          from pg_trigger g join pg_attribute a on a.attrelid = g.tgrelid and a.attnum = any(g.tgattr::int2[])
         where g.tgname = 'trg_escalation_closure' and g.tgrelid = 'public.work_items'::regclass)
       = array['meta','status','title'] then k := k + 1; end if;
    -- the owner's authenticated session reads the audit
    perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
    set local role authenticated;
    begin
      select count(*) into n from public.vw_escalation_closure_audit where ticket_code = 'SB-426';
    exception when others then n := -1;
    end;
    reset role;
    perform set_config('request.jwt.claims', '{}', true);
    if n = 1 then k := k + 1; end if;
    r := r || jsonb_build_object('TC-SB526-7', case
           when t = array['ok','violation','held','violation','ok','none','governance_violation'] and k = 8 then 'pass'
           else format('FAIL: verdicts %s, posture %s of 8', t, k) end);
  exception when others then
    reset role;
    r := r || jsonb_build_object('TC-SB526-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-8: meta / title writes cannot bypass the gate (warn)
  begin
    u8 := pg_temp.fx('ZZE-80', 'qa-sb526 upstream 8', 'blocked', null, null);
    d8 := pg_temp.fx('ZZE-81', 'qa-sb526 finished 8', 'done', qa, null);
    -- 8a: close and switch issue_type to handoff_gap in one update
    e8a := pg_temp.fx('ZZE-82', 'ESCALATION: qa-sb526 8a', 'todo', null, '{"upstream_ticket":"ZZE-80"}');
    update public.work_items set status = 'done', meta = meta || '{"issue_type":"handoff_gap"}' where id = e8a;
    -- 8b: meta-only repoint to a done ticket, snapshot removed then forged, then close
    e8b := pg_temp.fx('ZZE-83', 'ESCALATION: qa-sb526 8b', 'todo', null, '{"upstream_ticket":"ZZE-80"}');
    update public.work_items set meta = (meta - 'escalation_snapshot') || '{"upstream_ticket":"ZZE-81"}' where id = e8b;
    update public.work_items set meta = meta || '{"escalation_snapshot":{"upstream":"ZZE-81","status":"done"}}' where id = e8b;
    update public.work_items set status = 'done' where id = e8b;
    -- 8c: the verdict cannot be removed after the close
    update public.work_items set meta = meta - 'escalation_closure' where id = e8b;
    -- 8d: rename away from ESCALATION and strip the upstream key, then close
    e8d := pg_temp.fx('ZZE-84', 'ESCALATION: qa-sb526 8d', 'todo', null, '{"upstream_ticket":"ZZE-80"}');
    update public.work_items set title = 'qa-sb526 renamed 8d', meta = meta - 'upstream_ticket' where id = e8d;
    update public.work_items set status = 'done' where id = e8d;
    -- 8e: no snapshot at insert (upstream did not exist yet); the first write pins a legacy snapshot
    e8e := pg_temp.fx('ZZE-85', 'ESCALATION: qa-sb526 8e', 'todo', null, '{"upstream_ticket":"ZZE-86"}');
    u8e := pg_temp.fx('ZZE-86', 'qa-sb526 upstream 8e', 'blocked', null, null);
    update public.work_items set meta = meta || '{"upstream_ticket":"ZZE-81"}' where id = e8e;
    update public.work_items set status = 'done' where id = e8e;
    -- 8f: caller-supplied trigger-owned keys on a plain insert are stripped
    f8 := pg_temp.fx('ZZE-87', 'qa-sb526 plain 8f', 'todo', null,
                     '{"escalation_snapshot":{"upstream":"ZZE-80"},"escalation_closure":{"verdict":"x"}}');
    -- 8g: a plain row becomes an escalation and closes in one update
    g8 := pg_temp.fx('ZZE-88', 'qa-sb526 plain 8g', 'todo', null, null);
    update public.work_items set title = 'ESCALATION: qa-sb526 8g', meta = '{"upstream_ticket":"ZZE-80"}', status = 'done' where id = g8;
    select array[
      (select coalesce(meta->'escalation_closure'->>'verdict', 'none') from public.work_items where id = e8a),
      (select concat_ws('/', meta->'escalation_snapshot'->>'upstream', meta->'escalation_closure'->>'verdict',
                        meta->'escalation_closure'->>'upstream') from public.work_items where id = e8b),
      (select concat_ws('/', meta->'escalation_closure'->>'verdict', meta->'escalation_closure'->>'upstream')
         from public.work_items where id = e8d),
      (select concat_ws('/', meta->'escalation_snapshot'->>'legacy', meta->'escalation_closure'->>'verdict',
                        meta->'escalation_closure'->>'upstream') from public.work_items where id = e8e),
      (select (meta ? 'escalation_snapshot')::text || '/' || (meta ? 'escalation_closure')::text from public.work_items where id = f8),
      (select concat_ws('/', meta->'escalation_closure'->>'verdict', meta->'escalation_snapshot'->>'upstream')
         from public.work_items where id = g8),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'ZZE-84' and row_kind = 'escalation'), 'none'),
      coalesce((select verdict from public.vw_escalation_closure_audit where ticket_code = 'ZZE-85' and row_kind = 'escalation'), 'none')]
      into t;
    r := r || jsonb_build_object('TC-SB526-8', case
           when t = array['ESCALATION-002','ZZE-80/ESCALATION-002/ZZE-80','ESCALATION-002/ZZE-80','true/ESCALATION-001/ZZE-86',
                          'false/false','ESCALATION-001/ZZE-80','violation','violation'] then 'pass'
           else format('FAIL: %s', t) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB526-8', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB526-1e / 3e / 6e: enforce mode raises P0001
  begin
    begin
      execute $ddl$create or replace function public.escalation_gate_mode(p_gate text)
        returns text language sql stable set search_path = public as $g$ select 'enforce'::text $g$$ddl$;
      -- 1e
      xid := pg_temp.fx('ZZE-70', 'qa-sb526 upstream 1e', 'blocked', null, null);
      xid := pg_temp.fx('ZZE-71', 'ESCALATION: qa-sb526 escalation 1e', 'todo', null, '{"upstream_ticket":"ZZE-70"}');
      update public.work_items set assignee = qa where ticket_code = 'ZZE-70';
      st := 'ok'; msg := '';
      begin
        update public.work_items set status = 'done' where ticket_code = 'ZZE-71';
      exception when others then st := sqlstate; msg := sqlerrm;
      end;
      r := r || jsonb_build_object('TC-SB526-1e', case
             when st = 'P0001' and msg like 'ESCALATION-001: escalation ZZE-71 %' and
                  (select status from public.work_items where ticket_code = 'ZZE-71') = 'todo' then 'pass'
             else format('FAIL: %s', st) end);
      -- 3e
      xid := pg_temp.fx('ZZE-72', 'qa-sb526 upstream 3e', 'blocked', qa, null);
      xid := pg_temp.fx('ZZE-73', 'ESCALATION: qa-sb526 escalation 3e', 'todo', null, '{"upstream_ticket":"ZZE-72"}');
      st := 'ok'; msg := '';
      begin
        update public.work_items set status = 'done' where ticket_code = 'ZZE-73';
      exception when others then st := sqlstate; msg := sqlerrm;
      end;
      r := r || jsonb_build_object('TC-SB526-3e', case when st = 'P0001' and msg like 'ESCALATION-002: escalation ZZE-73 %' then 'pass'
             else format('FAIL: %s', st) end);
      -- 6e
      xid := pg_temp.fx('ZZE-74', 'qa-sb526 upstream 6e', 'blocked', null, null);
      st := 'ok'; msg := '';
      begin
        -- no ticket_code: trg_generate_ticket_code fires after the gate, so the message says 'new row'
        insert into public.work_items (project_id, user_id, title, type, status, priority, approval_status, meta)
          values (pj, ub, 'ESCALATION: qa-sb526 escalation 6e', 'chore', 'done', 'high', 'not_required', '{"upstream_ticket":"ZZE-74"}');
      exception when others then st := sqlstate; msg := sqlerrm;
      end;
      r := r || jsonb_build_object('TC-SB526-6e', case
             when st = 'P0001' and msg like 'ESCALATION-001: escalation new row %'
              and not exists (select 1 from public.work_items where title = 'ESCALATION: qa-sb526 escalation 6e') then 'pass'
             else format('FAIL: %s', st) end);
      -- 8e: the U5 and U7 bypasses are refused
      xid := pg_temp.fx('ZZE-75', 'qa-sb526 upstream 8e-enforce', 'blocked', null, null);
      xid := pg_temp.fx('ZZE-77', 'qa-sb526 finished 8e-enforce', 'done', qa, null);
      xid := pg_temp.fx('ZZE-76', 'ESCALATION: qa-sb526 escalation 8e', 'todo', null, '{"upstream_ticket":"ZZE-75"}');
      update public.work_items set assignee = qa where ticket_code = 'ZZE-75';
      st := 'ok'; msg := '';
      begin
        update public.work_items set status = 'done', meta = meta || '{"issue_type":"handoff_gap"}' where ticket_code = 'ZZE-76';
      exception when others then st := sqlstate; msg := sqlerrm;
      end;
      update public.work_items set meta = (meta - 'escalation_snapshot') || '{"upstream_ticket":"ZZE-77"}' where ticket_code = 'ZZE-76';
      st2 := 'ok'; msg2 := '';
      begin
        update public.work_items set status = 'done' where ticket_code = 'ZZE-76';
      exception when others then st2 := sqlstate; msg2 := sqlerrm;
      end;
      r := r || jsonb_build_object('TC-SB526-8e', case
             when st = 'P0001' and msg like 'ESCALATION-001: escalation ZZE-76 %'
              and st2 = 'P0001' and msg2 like 'ESCALATION-001: escalation ZZE-76 cannot close while upstream ZZE-75 is blocked %'
              and (select status from public.work_items where ticket_code = 'ZZE-76') = 'todo' then 'pass'
             else format('FAIL: handoff switch %s, repoint %s', st, st2) end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB526-enforce', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    if public.escalation_gate_mode('SB-526') <> 'warn' then
      r := r || jsonb_build_object('TC-SB526-enforce', 'FAIL: gate mode not restored inside the suite');
    end if;
  end;

  reset role;
  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'ESCALATION_CLOSURE_GATE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'ESCALATION_CLOSURE_GATE FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
