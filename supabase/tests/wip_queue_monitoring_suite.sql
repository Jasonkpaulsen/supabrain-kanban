-- WIP queue monitoring suite: TC-SB598-1..6 (SB-598; ADR-FLOW-005 D10).
--
-- Run as postgres. One transaction that always ends by raising, so nothing it creates or
-- inserts survives. Fixtures are SB-project tasks (L1, approval not_required) owned by the
-- owner, with ticket codes outside every project's numbering (ZZQ-n). Each case sets the
-- System Architect wip_limits row to the live in_progress count + 1 inside its own rolled-back
-- sub-block, so one admitted fixture fills the slot and the next one is parked by
-- enforce_wip_limit. SupaBrain QA has no wip_limits row and is filled to its agents limit.
-- If another gate refuses a fixture write, the case records 'blocked: <sqlstate>'.
-- Pass = the raised message starts with "WIP_QUEUE_MONITORING PASS". The message carries only
-- counts, booleans, statuses and sqlstates, never titles or free text.

do $suite$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  sa  constant text := 'System Architect';
  qa  constant text := 'SupaBrain QA';
  rb  constant text := '__sb598_rollback__';
  r jsonb := '{}'::jsonb;
  lim int; qlim int; qfill int;
  a uuid; b uuid; q uuid; m1 uuid; s1 uuid; qx uuid; p1 uuid; p2 uuid;
  sta text; stb text; gb text; stq text; stage text;
  n int; m int; k int; j int; fails int; qt text; qc int; ok boolean; msg text;
begin
  execute $f$create function pg_temp.fx(p_code text, p_prio text, p_status text, p_assignee text, p_meta jsonb)
    returns uuid language plpgsql as $b$
    declare v uuid;
    begin
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status,
                                     authority_level, assignee, meta)
      values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', p_code,
              'qa-sb598 fixture ' || p_code, 'task', p_status, p_prio, 'not_required', 1, p_assignee,
              coalesce(p_meta, '{}'::jsonb))
      returning id into v;
      return v;
    end $b$$f$;

  -- System Architect limit = live in_progress + 1, so one admitted fixture fills the slot.
  execute $f$create function pg_temp.set_sa_limit() returns int language plpgsql as $b$
    declare c int;
    begin
      select count(*) into c from public.work_items
       where user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5' and assignee = 'System Architect' and status = 'in_progress';
      insert into public.wip_limits (assignee, max_wip) values ('System Architect', c + 1)
        on conflict (assignee) do update set max_wip = excluded.max_wip;
      return c + 1;
    end $b$$f$;

  -- SupaBrain QA: fill to its resolved limit with admitted fixtures; returns the limit.
  execute $f$create function pg_temp.fill_qa(p_prefix text) returns int language plpgsql as $b$
    declare l int; c int; i int;
    begin
      l := coalesce((select wl.max_wip from public.wip_limits wl where wl.assignee = 'SupaBrain QA' limit 1),
                    (select a.max_concurrent_tasks from public.agents a
                      where a.name = 'SupaBrain QA' and a.user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5' limit 1),
                    5);
      select count(*) into c from public.work_items
       where user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5' and assignee = 'SupaBrain QA' and status = 'in_progress';
      for i in 1 .. greatest(l - c, 0) loop
        perform pg_temp.fx(p_prefix || i, 'medium', 'in_progress', 'SupaBrain QA', null);
      end loop;
      return l;
    end $b$$f$;

  -- ------------------------------------------------ TC-SB598-1: a parked ticket appears in v_wip_queue
  begin
    begin
      stage := 'fixture';
      lim := pg_temp.set_sa_limit();
      a := pg_temp.fx('ZZQ-1A', 'medium', 'in_progress', sa, null);
      b := pg_temp.fx('ZZQ-1B', 'medium', 'in_progress', sa, null);
      stage := 'check';
      select status into sta from public.work_items where id = a;
      select status, held_by_gate into stb, gb from public.work_items where id = b;
      select count(*) into n from public.v_wip_queue where assignee = sa;
      select count(*) into m from public.v_wip_queue
       where id = b and blocked_at is not null and queue_age >= interval '0'
         and current_wip = lim and wip_limit = lim and not slot_available;
      r := r || jsonb_build_object('TC-SB598-1', case
             when sta = 'in_progress' and stb = 'on_hold' and gb = 'enforce_wip_limit' and n = 1 and m = 1 then 'pass'
             else format('FAIL: A %s, B %s/%s, queue rows %s, matching %s', sta, stb, coalesce(gb, 'null'), n, m) end);
      r := r || jsonb_build_object('TC-SB598-1.evidence',
             format('limit %s; A %s; B %s held_by_gate %s; SA queue rows %s; B row current_wip=wip_limit=%s, slot_available false: %s',
                    lim, sta, stb, gb, n, lim, m = 1));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB598-1', case when stage = 'fixture' then 'blocked: ' || sqlstate
               else 'FAIL: error ' || sqlstate || ' ' || sqlerrm end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB598-2: limit resolved as the gate does; bad timestamp is NULL
  begin
    begin
      stage := 'fixture';
      lim := pg_temp.set_sa_limit();
      a := pg_temp.fx('ZZQ-2A', 'medium', 'in_progress', sa, null);
      b := pg_temp.fx('ZZQ-2B', 'medium', 'in_progress', sa, null);
      qlim := pg_temp.fill_qa('ZZQ-2F');
      q := pg_temp.fx('ZZQ-2Q', 'medium', 'in_progress', qa, null);
      stage := 'check';
      select count(*) into n from public.v_wip_queue v join public.work_items w on w.id = v.id
       where v.id in (b, q) and v.wip_limit = (w.meta->>'wip_blocked_limit')::int;
      select count(*) into k from public.wip_limits where assignee = qa;
      select count(*) into m from public.v_wip_queue v
       where v.id = q and v.wip_limit = (select a2.max_concurrent_tasks from public.agents a2 where a2.name = qa and a2.user_id = ub limit 1);
      select count(*) into j from public.v_wip_queue v where v.id = b and v.wip_limit = lim;
      stage := 'fixture';
      update public.work_items set meta = meta || '{"wip_blocked_at":"not-a-time"}'::jsonb where id = q;
      stage := 'check';
      msg := 'ok';
      begin
        select count(*) into qc from public.v_wip_queue where id = q and blocked_at is null and queue_age is null;
      exception when others then msg := sqlstate; qc := -1;
      end;
      r := r || jsonb_build_object('TC-SB598-2', case
             when n = 2 and k = 0 and m = 1 and j = 1 and msg = 'ok' and qc = 1 then 'pass'
             else format('FAIL: view=meta limit %s of 2, QA wip_limits rows %s, agents fallback %s, SA wip_limits %s, bad timestamp %s rows %s',
                         n, k, m, j, msg, qc) end);
      r := r || jsonb_build_object('TC-SB598-2.evidence',
             format('SA limit %s (wip_limits), QA limit %s (agents); view equals gate meta for %s of 2; bad wip_blocked_at read %s, NULL rows %s',
                    lim, qlim, n, msg, qc));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB598-2', case when stage = 'fixture' then 'blocked: ' || sqlstate
               else 'FAIL: error ' || sqlstate || ' ' || sqlerrm end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB598-3: slot opening logs wip_slot_opened with the parked ticket
  begin
    begin
      stage := 'fixture';
      lim := pg_temp.set_sa_limit();
      a := pg_temp.fx('ZZQ-3A', 'medium', 'in_progress', sa, null);
      b := pg_temp.fx('ZZQ-3B', 'medium', 'in_progress', sa, null);
      update public.work_items set status = 'todo' where id = a;
      stage := 'check';
      select count(*), max((meta->>'queued_count')::int), bool_and(position('ZZQ-3B' in meta->>'queued_tickets') > 0)
        into n, qc, ok
        from public.activity_log
       where meta->>'event' = 'wip_slot_opened' and meta->>'source_ticket' = 'ZZQ-3A';
      select count(*) into m from public.v_wip_queue where id = b and slot_available and current_wip = lim - 1;
      r := r || jsonb_build_object('TC-SB598-3', case
             when n = 1 and qc = 1 and ok and m = 1 then 'pass'
             else format('FAIL: events %s, queued_count %s, lists B %s, B slot_available %s', n, qc, ok, m) end);
      r := r || jsonb_build_object('TC-SB598-3.evidence',
             format('wip_slot_opened events %s, queued_count %s, lists B %s; B slot_available with current_wip %s of %s: %s',
                    n, qc, ok, lim - 1, lim, m = 1));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB598-3', case when stage = 'fixture' then 'blocked: ' || sqlstate
               else 'FAIL: error ' || sqlstate || ' ' || sqlerrm end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB598-4: dead meta marker and stale meta assignee are ignored
  begin
    begin
      stage := 'fixture';
      lim := pg_temp.set_sa_limit();
      a := pg_temp.fx('ZZQ-4A', 'medium', 'in_progress', sa, null);
      m1 := pg_temp.fx('ZZQ-4M', 'medium', 'on_hold', sa,
                       '{"hold_reason":"wip_limit","wip_blocked_assignee":"System Architect"}'::jsonb);
      s1 := pg_temp.fx('ZZQ-4S', 'medium', 'in_progress', sa, null);
      update public.work_items set meta = meta || '{"hold_reason":"wip_limit","wip_blocked_assignee":"SupaBrain QA"}'::jsonb
       where id = s1;
      qx := pg_temp.fx('ZZQ-4X', 'medium', 'in_progress', qa, null);
      select status into stq from public.work_items where id = qx;
      update public.work_items set status = 'todo' where id = qx;
      update public.work_items set status = 'todo' where id = a;
      stage := 'check';
      select status, held_by_gate into stb, gb from public.work_items where id = s1;
      select count(*) into n from public.v_wip_queue where id = m1;
      select count(*) into m from public.v_wip_queue where id = s1 and assignee = sa;
      select count(*), max((meta->>'queued_count')::int),
             bool_and(position('ZZQ-4S' in meta->>'queued_tickets') > 0 and position('ZZQ-4M' in meta->>'queued_tickets') = 0)
        into k, qc, ok
        from public.activity_log
       where meta->>'event' = 'wip_slot_opened' and meta->>'source_ticket' = 'ZZQ-4A';
      select count(*) into j from public.activity_log
       where meta->>'event' = 'wip_slot_opened' and meta->>'source_ticket' = 'ZZQ-4X';
      r := r || jsonb_build_object('TC-SB598-4', case
             when stb = 'on_hold' and gb = 'enforce_wip_limit' and stq = 'in_progress'
              and n = 0 and m = 1 and k = 1 and qc = 1 and ok and j = 0 then 'pass'
             else format('FAIL: stale fixture %s/%s, QA probe %s, meta-only in view %s, stale under live assignee %s, SA events %s queued %s lists only stale %s, QA events %s',
                         stb, coalesce(gb, 'null'), stq, n, m, k, qc, ok, j) end);
      r := r || jsonb_build_object('TC-SB598-4.evidence',
             format('meta-only on_hold rows in view %s; stale-meta parked row under live assignee %s; SA wip_slot_opened %s with queued_count %s (meta-only absent, stale listed: %s); QA slot events %s',
                    n, m, k, qc, ok, j));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB598-4', case when stage = 'fixture' then 'blocked: ' || sqlstate
               else 'FAIL: error ' || sqlstate || ' ' || sqlerrm end);
      end if;
    end;
  end;

  -- ------------------------------------------------ TC-SB598-5: posture
  begin
    select count(*) into n from pg_class c
     where c.oid = 'public.v_wip_queue'::regclass and c.relkind = 'v'
       and c.reloptions @> array['security_invoker=true']
       and not has_table_privilege('anon', c.oid, 'select')
       and has_table_privilege('authenticated', c.oid, 'select')
       and has_table_privilege('service_role', c.oid, 'select');
    select count(*) into m from pg_proc p
     where p.oid = 'public.notify_wip_slot_opened()'::regprocedure
       and not p.prosecdef and p.proconfig @> array['search_path=public']
       and p.prorettype = 'trigger'::regtype
       and position('hold_reason' in p.prosrc) = 0
       and position('held_by_gate = ''enforce_wip_limit''' in p.prosrc) > 0
       and position('assignee = v_assignee' in p.prosrc) > 0;
    select count(*) into k from pg_trigger t
     where t.tgrelid = 'public.work_items'::regclass and t.tgname = 'trg_notify_wip_slot_opened'
       and t.tgenabled = 'O' and t.tgfoid = 'public.notify_wip_slot_opened()'::regprocedure;
    select count(*) into j from pg_proc p
     where p.oid = 'public.enforce_wip_limit()'::regprocedure
       and position('held_by_gate := ''enforce_wip_limit''' in p.prosrc) > 0;
    select count(*) into qc from (
      select string_agg(a2.attname, ',' order by a2.attnum) cols from pg_attribute a2
       where a2.attrelid = 'public.v_wip_queue'::regclass and a2.attnum > 0) x
     where x.cols = 'id,user_id,project_id,ticket_code,title,priority,assignee,blocked_at,queue_age,current_wip,wip_limit,slot_available';
    r := r || jsonb_build_object('TC-SB598-5', case when n = 1 and m = 1 and k = 1 and j = 1 and qc = 1 then 'pass'
           else format('FAIL: view %s, function %s, trigger %s, gate %s, columns %s', n, m, k, j, qc) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB598-5', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB598-6: second assignee isolated; order is priority then blocked_at
  begin
    begin
      stage := 'fixture';
      lim := pg_temp.set_sa_limit();
      a := pg_temp.fx('ZZQ-6A', 'medium', 'in_progress', sa, null);
      p1 := pg_temp.fx('ZZQ-6L', 'low', 'in_progress', sa, null);
      p2 := pg_temp.fx('ZZQ-6C', 'critical', 'in_progress', sa, null);
      qlim := pg_temp.fill_qa('ZZQ-6F');
      q := pg_temp.fx('ZZQ-6Q', 'medium', 'in_progress', qa, null);
      update public.work_items set status = 'todo' where id = a;
      stage := 'check';
      select max((meta->>'queued_count')::int), max(meta->>'queued_tickets'), count(*)
        into qc, qt, k
        from public.activity_log
       where meta->>'event' = 'wip_slot_opened' and meta->>'source_ticket' = 'ZZQ-6A';
      ok := k = 1 and position('ZZQ-6C' in qt) > 0 and position('ZZQ-6L' in qt) > position('ZZQ-6C' in qt)
            and position('ZZQ-6Q' in qt) = 0;
      select count(*) into n from public.v_wip_queue
       where id = q and assignee = qa and current_wip = qlim and wip_limit = qlim and not slot_available;
      select count(*) into m from public.v_wip_queue
       where id in (p1, p2) and assignee = sa and current_wip = lim - 1 and wip_limit = lim and slot_available;
      r := r || jsonb_build_object('TC-SB598-6', case
             when qc = 2 and ok and n = 1 and m = 2 then 'pass'
             else format('FAIL: events %s, queued_count %s, critical before low and QA absent %s, QA row %s, SA rows %s',
                         k, qc, ok, n, m) end);
      r := r || jsonb_build_object('TC-SB598-6.evidence',
             format('SA event queued_count %s, critical listed before low and QA fixture absent %s; QA row own wip %s/%s %s; SA rows slot_available %s of 2',
                    qc, ok, qlim, qlim, n = 1, m));
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then
        r := r || jsonb_build_object('TC-SB598-6', case when stage = 'fixture' then 'blocked: ' || sqlstate
               else 'FAIL: error ' || sqlstate || ' ' || sqlerrm end);
      end if;
    end;
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'WIP_QUEUE_MONITORING PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'WIP_QUEUE_MONITORING FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
