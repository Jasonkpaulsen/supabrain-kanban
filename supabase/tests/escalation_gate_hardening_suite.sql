-- Escalation gate hardening suite: TC-SB607-1, -2, -4, -7 (SB-607; ADR-FLOW-005 D6-D8).
-- TC-SB607-3 and -6 are the re-runs of escalation_closure_gate_suite.sql and
-- jason_decision_digest_suite.sql; TC-SB607-5 moved to its own follow-up ticket.
--
-- Run as postgres. One transaction that always ends by raising, so nothing it creates survives.
-- Fixtures are SB-project chores owned by the owner with codes outside every numbering (ZZH-n).
-- Pass = the raised message starts with "ESCALATION_GATE_HARDENING PASS". Counts, codes,
-- verdicts and sqlstates only.

do $suite$
declare
  ub  constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';   -- owner
  qa  constant text := 'SupaBrain QA';
  rb  constant text := '__sb607_rollback__';
  r jsonb := '{}'::jsonb;
  u uuid; e uuid; p uuid; snap0 jsonb; t text[]; st text; msg text; k int; n int; m int; fails int;
begin
  execute $f$create function pg_temp.fx(p_code text, p_title text, p_status text, p_assignee text, p_meta jsonb)
    returns uuid language plpgsql as $b$
    declare v uuid;
    begin
      insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status,
                                     assignee, meta)
      values ('a07a7f3d-722f-468f-81fa-84e2c5fba704', '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', p_code, p_title, 'chore',
              p_status, 'high', 'not_required', p_assignee, coalesce(p_meta, '{}'::jsonb))
      returning id into v;
      return v;
    end $b$$f$;

  -- ------------------------------------------------ TC-SB607-1: the stored snapshot cannot be rewritten or removed
  begin
    u := pg_temp.fx('ZZH-1', 'qa-sb607 upstream 1', 'blocked', null, null);
    e := pg_temp.fx('ZZH-2', 'ESCALATION: qa-sb607 escalation 1', 'todo', null, '{"upstream_ticket":"ZZH-1"}');
    select meta->'escalation_snapshot' into snap0 from public.work_items where id = e;
    k := 0;
    update public.work_items set meta = meta || '{"escalation_snapshot":{"upstream":"ZZH-1","status":"done"}}' where id = e;
    if (select meta->'escalation_snapshot' from public.work_items where id = e) = snap0 then k := k + 1; end if;
    update public.work_items set meta = '{"note":"replaced whole"}' where id = e;
    if (select meta->'escalation_snapshot' from public.work_items where id = e) = snap0
       and (select meta->>'note' from public.work_items where id = e) = 'replaced whole' then k := k + 1; end if;
    update public.work_items set meta = meta || '{"other":1}' where id = e;
    if (select meta->'escalation_snapshot' from public.work_items where id = e) = snap0
       and (select meta->>'other' from public.work_items where id = e) = '1' then k := k + 1; end if;
    r := r || jsonb_build_object('TC-SB607-1', case when snap0 is not null and k = 3 then 'pass'
           else format('FAIL: snapshot taken %s, kept %s of 3', snap0 is not null, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB607-1', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB607-2: edit-then-close bypasses refused (enforce)
  begin
    begin
      execute $ddl$create or replace function public.escalation_gate_mode(p_gate text)
        returns text language sql stable set search_path = public as $g$ select 'enforce'::text $g$$ddl$;
      u := pg_temp.fx('ZZH-10', 'qa-sb607 upstream 2', 'blocked', null, null);
      p := pg_temp.fx('ZZH-11', 'qa-sb607 finished 2', 'done', qa, null);
      k := 0; msg := '';
      -- (a) meta-only repoint to a done ticket, then close
      e := pg_temp.fx('ZZH-12', 'ESCALATION: qa-sb607 2a', 'todo', null, '{"upstream_ticket":"ZZH-10"}');
      update public.work_items set meta = meta || '{"upstream_ticket":"ZZH-11"}' where id = e;
      st := 'ok'; begin update public.work_items set status = 'done' where id = e; exception when others then st := sqlstate || ' ' || left(sqlerrm, 160); end;
      if st like 'P0001 ESCALATION-00% ZZH-12 cannot close while upstream ZZH-10%' then k := k + 1; else msg := msg || '[a ' || st || '] '; end if;
      -- (b) issue_type switched to handoff in a separate update, then close
      e := pg_temp.fx('ZZH-13', 'ESCALATION: qa-sb607 2b', 'todo', null, '{"upstream_ticket":"ZZH-10"}');
      update public.work_items set meta = meta || '{"issue_type":"handoff_gap"}' where id = e;
      st := 'ok'; begin update public.work_items set status = 'done' where id = e; exception when others then st := sqlstate || ' ' || left(sqlerrm, 160); end;
      if st like 'P0001 ESCALATION-00% ZZH-13 %' then k := k + 1; else msg := msg || '[b ' || st || '] '; end if;
      -- (c) title renamed away from ESCALATION, then close
      e := pg_temp.fx('ZZH-14', 'ESCALATION: qa-sb607 2c', 'todo', null, '{"upstream_ticket":"ZZH-10"}');
      update public.work_items set title = 'qa-sb607 renamed 2c' where id = e;
      st := 'ok'; begin update public.work_items set status = 'done' where id = e; exception when others then st := sqlstate || ' ' || left(sqlerrm, 160); end;
      if st like 'P0001 ESCALATION-00% ZZH-14 %' then k := k + 1; else msg := msg || '[c ' || st || '] '; end if;
      -- (d) control: the upstream really is resolved -> the close goes through
      e := pg_temp.fx('ZZH-15', 'ESCALATION: qa-sb607 2d', 'todo', null, '{"upstream_ticket":"ZZH-10"}');
      update public.work_items set status = 'done' where id = u;
      st := 'ok'; begin update public.work_items set status = 'done' where id = e; exception when others then st := sqlstate; end;
      if st = 'ok' then k := k + 1; else msg := msg || '[d ' || st || '] '; end if;
      r := r || jsonb_build_object('TC-SB607-2', case when k = 4 then 'pass' else 'FAIL: ' || msg end);
      raise exception '%', rb;
    exception when others then
      if sqlerrm <> rb then r := r || jsonb_build_object('TC-SB607-2', 'FAIL: error ' || sqlstate || ' ' || sqlerrm); end if;
    end;
    if public.escalation_gate_mode('SB-526') <> 'warn' then
      r := r || jsonb_build_object('TC-SB607-2.mode', 'FAIL: gate mode not restored');
    end if;
  end;

  -- ------------------------------------------------ TC-SB607-4: every human-decision escalation is visible once
  begin
    with esc as (
      select e2.user_id, e2.ticket_code, e2.authority_level,
             coalesce(e2.meta->>'blocker_class',
                      case when coalesce(e2.authority_level, 0) >= 3 or e2.status = 'awaiting_jason' or e2.meta->>'flagged_for_jason' = 'true'
                           then 'human_decision'
                           else public.jason_blocker_class(public.escalation_subject_codes(e2.meta)) end) as blocker_class
        from public.work_items e2
       where e2.title ilike 'ESCALATION%' and e2.status not in ('done', 'cancelled') and not e2.archived)
    select count(*) filter (where not exists (select 1 from public.vw_jason_decision_digest d
                                               where d.user_id = esc.user_id
                                                 and (d.ticket_code = esc.ticket_code or esc.ticket_code = any (d.escalations_attached)))),
           count(*)
      into n, k
      from esc where esc.blocker_class = 'human_decision' or coalesce(esc.authority_level, 0) >= 3;
    -- no escalation is listed twice (as its own row and attached to another)
    m := (select count(*) from public.vw_jason_decision_digest d, unnest(d.escalations_attached) x
           where exists (select 1 from public.vw_jason_decision_digest d2 where d2.user_id = d.user_id and d2.ticket_code = x));
    -- attach vs orphan on fixtures, not live tickets (live ones move: SB-520 lost its awaiting_jason subject
    -- SB-413 on 2026-10-18). ZZH-41 escalates ZZH-40, which waits on Jason, so it is attached there;
    -- ZZH-42 escalates a plain blocked ticket, so it is listed as its own row.
    u := pg_temp.fx('ZZH-40', 'qa-sb607 waiting on Jason 4', 'awaiting_jason', null, null);
    e := pg_temp.fx('ZZH-41', 'ESCALATION: qa-sb607 4 attached', 'todo', null, '{"upstream_ticket":"ZZH-40","flagged_for_jason":"true"}');
    p := pg_temp.fx('ZZH-43', 'qa-sb607 upstream 4', 'blocked', null, null);
    e := pg_temp.fx('ZZH-42', 'ESCALATION: qa-sb607 4 orphan', 'todo', null, '{"upstream_ticket":"ZZH-43","flagged_for_jason":"true"}');
    t := array[
      coalesce((select array_to_string(escalations_attached, ',') from public.vw_jason_decision_digest where ticket_code = 'ZZH-40'), 'no row'),
      (select count(*)::text from public.vw_jason_decision_digest where ticket_code = 'ZZH-41'),
      coalesce((select string_agg(row_kind, ',') from public.vw_jason_decision_digest where ticket_code = 'ZZH-42'), 'no row')];
    r := r || jsonb_build_object('TC-SB607-4', case
           when n = 0 and m = 0 and t = array['ZZH-41', '0', 'orphan_escalation'] then 'pass'
           else format('FAIL: missing %s of %s; listed twice %s; fixture attached %s, attached listed as row %s, orphan %s',
                       n, k, m, t[1], t[2], t[3]) end);
    r := r || jsonb_build_object('TC-SB607-4.evidence', format('%s human-decision escalations, %s missing; digest rows %s',
                                   k, n, (select count(*) from public.vw_jason_decision_digest)));
  exception when others then
    r := r || jsonb_build_object('TC-SB607-4', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  -- ------------------------------------------------ TC-SB607-7: a plain ticket that names a code is not an escalation
  begin
    u := pg_temp.fx('ZZH-30', 'qa-sb607 upstream 7', 'blocked', null, null);
    e := pg_temp.fx('ZZH-31', 'BUG: follow-ups for ZZH-30', 'todo', null, '{"found_by":"qa-sb607"}');
    update public.work_items set status = 'done' where id = e;
    select array[(meta ? 'escalation_snapshot')::text, (meta ? 'escalation_closure')::text, status]
      into t from public.work_items where id = e;
    k := (select count(*) from public.work_items where meta ? 'escalation_snapshot' and not public.escalation_in_scope(title, meta));
    r := r || jsonb_build_object('TC-SB607-7', case when t = array['false', 'false', 'done'] and k = 0 then 'pass'
           else format('FAIL: %s; plain rows with a snapshot %s', t, k) end);
  exception when others then
    r := r || jsonb_build_object('TC-SB607-7', 'FAIL: error ' || sqlstate || ' ' || sqlerrm);
  end;

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'ESCALATION_GATE_HARDENING PASS (% checks): %', (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  else
    raise exception 'ESCALATION_GATE_HARDENING FAIL (% of % checks): %', fails,
      (select count(*) from jsonb_object_keys(r) x where x not like '%.evidence'), r::text;
  end if;
end $suite$;
