-- SB-646 (option A): agent guidance matches SB-644 (ADR-GOV-001-A2). TC-SB646-01, -03.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "AGENT_GOVERNANCE_GUIDANCE PASS".
--
-- TC-SB646-01 reads the live guidance: every text field of the non-archived agents, the
-- non-archived skills they follow, and the approval gate's refusal message. A sentence that sends
-- work to awaiting_jason (or "Awaiting Jason", "awaiting-on-Jason") must scope it to L2+ work:
-- name L3/L4 or L2+, tell the agent to raise authority_level to 2 or higher, or be a read-only
-- SELECT ... FROM query. It fails anyway if it says "when in doubt" or points L0/L1 work there.
-- JSON is split at element and key boundaries as well as at sentence ends. The SB-646 edits are
-- pinned from SB-646 meta (rollback_agent_edits, rollback_other_edits): each new text is present
-- exactly once, the old text is gone, and putting the old text back makes the checker fail (except
-- the cancellation runbook edit, which TC-SB646-03's reopen checks prove instead).
-- TC-SB646-03 exercises the database behaviour the guidance tells agents to rely on. Fixtures use
-- ticket codes outside every project's numbering (ZZH-*), have no assignee (no WIP gate) and use
-- approval_status not_required. Every step with a side effect runs on its own line, in order.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb; fails int; st text; n int; bad text; msg text;
  e record; live text; t1 uuid; t2 uuid; t3 uuid; t4 uuid;
begin
  -- number of sentences in a text that send work to awaiting_jason without scoping it to L2+
  execute $f$create or replace function pg_temp.unscoped(txt text) returns int language sql immutable as $b$
    select count(*)::int from regexp_split_to_table(coalesce(txt, ''), '(\.\s|;\s|\n|\\n|"\s*[,:]\s*")') s
    where s ~* '(awaiting(_|-)(on(_|-))?jason|(\mto|\minto|status)\s+\W?awaiting\s+(on\s+)?jason)'
      and (s ~* 'when in doubt'
           or s ~* '\m(L0|L1)[^,.;]{0,40}\m(in|to|into|via)\s+\W?awaiting'
           or s ~* 'awaiting[\s_-]*(on[\s_-]*)?jason\W*\s+(for|with)\s+(L0|L1)'
           or s !~* '(L3/L4|L2\+|authority_level (2 or higher|to at least 2)|at authority_level 2|select\s.+\sfrom\s)') $b$$f$;
  execute $f$create or replace function pg_temp.field(p_tbl text, p_id text, p_k text) returns text language plpgsql stable as $b$
    declare v text;
    begin
      if p_tbl = 'skills' then
        select case p_k when 'examples' then array_to_string(s.examples, E'\n') end into v from public.skills s where s.skill_id = p_id;
      elsif p_tbl = 'reference_items' then
        select case p_k when 'content' then ri.content end into v from public.reference_items ri where ri.id = p_id::uuid;
      else
        select case p_k when 'system_prompt' then a.system_prompt
                      when 'constraints' then array_to_string(a.constraints, E'\n')
                      when 'meta' then a.meta::text end into v from public.agents a where a.id = p_id::uuid;
      end if;
      return v;
    end $b$$f$;
  execute $f$create or replace function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'GOV-001 (SB-644)%' then 'SB-644'
                                         when sqlerrm like 'GOV-001%' then 'GOV-001'
                                         when sqlerrm like 'CANCEL-005%' then 'CANCEL-005'
                                         else sqlstate || ': ' || left(sqlerrm, 80) end;
    end $b$$f$;
  execute $f$create or replace function pg_temp.mk(code text, lvl int, st text) returns uuid language sql as $b$
    insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
    values ((select id from public.projects where project_key = 'SB'), '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', code,
            'qa-sb646 ' || code, 'task', st, 'low', 'not_required', lvl) returning id $b$$f$;

  -- TC-SB646-01: the checker itself (the unscoped probes are the SB-646 verifier's M2-M7)
  select string_agg(p, ' | ') into bad from unnest(array[
      'Escalate to Jason via awaiting_jason. Done.',
      'When in doubt, awaiting_jason',
      'Put L0/L1 tickets in awaiting_jason, not L2+ ones.',
      'When in doubt, select awaiting_jason as the status.',
      '{"rules": ["at authority_level 2 or higher (SB-644)", "when in doubt, set status awaiting_jason"]}',
      'park the ticket on Jason''s decision queue (status awaiting-on-Jason)',
      'move the ticket to Awaiting Jason',
      'use awaiting_jason for L1 work']) p
  where pg_temp.unscoped(p) <> 1;
  select nullif(concat_ws(' | ', bad, string_agg(p, ' | ')), '') into bad from unnest(array[
      'For L3/L4 items use status=''awaiting_jason''.',
      'Use status=awaiting_jason, set authority_level to at least 2 (L0/L1 tickets cannot wait on Jason: SB-644)',
      'SELECT * FROM work_items WHERE status=''awaiting_jason'' ORDER BY authority_level',
      'recommendations awaiting Jason''s approval']) p
  where pg_temp.unscoped(p) <> 0;
  r := r || jsonb_build_object('TC-SB646-01.checker', case when bad is null then 'pass' else 'FAIL: ' || bad end);

  -- TC-SB646-01: no live agent sends unscoped work to awaiting_jason
  select string_agg(a.name || '/' || f.k, ', ' order by a.name, f.k) into bad
  from public.agents a
  cross join lateral (values ('system_prompt', a.system_prompt), ('description', a.description),
                             ('constraints', array_to_string(a.constraints, E'\n')), ('goals', array_to_string(a.goals, E'\n')),
                             ('escalation_rules', a.escalation_rules::text), ('priority_rules', a.priority_rules::text),
                             ('auto_assign_rules', a.auto_assign_rules::text), ('trigger_config', a.trigger_config::text),
                             ('meta', a.meta::text), ('tags', array_to_string(a.tags, E'\n'))) f(k, v)
  where a.user_id = ub and a.status <> 'archived' and pg_temp.unscoped(f.v) > 0;
  r := r || jsonb_build_object('TC-SB646-01.agents', case when bad is null then 'pass' else 'FAIL: ' || bad end);

  -- the checker has something to look at: the active agents still mention awaiting_jason
  select count(*) into n from public.agents a
  where a.user_id = ub and a.status <> 'archived'
    and concat_ws(' ', a.system_prompt, array_to_string(a.constraints, ' '), a.escalation_rules::text, a.meta::text) ilike '%awaiting_jason%';
  r := r || jsonb_build_object('TC-SB646-01.coverage', case when n >= 30 then 'pass' else 'FAIL: ' || n end);

  -- the skills agents follow. crm-data-steward describes its weekly digest ticket as awaiting_jason;
  -- that ticket carries no authority_level (NULL), which SB-644 lets wait, so it is exempt only while
  -- crm_steward_digest() still sets no level
  select string_agg(s.skill_id || '/' || f.k, ', ' order by s.skill_id, f.k) into bad
  from public.skills s
  cross join lateral (values ('description', s.description), ('content', s.content), ('rules', array_to_string(s.rules, E'\n')),
                             ('examples', array_to_string(s.examples, E'\n')), ('meta', s.meta::text)) f(k, v)
  where not s.archived and pg_temp.unscoped(f.v) > 0
    and not (s.skill_id = 'crm-data-steward' and pg_get_functiondef('public.crm_steward_digest'::regproc) !~* 'authority_level');
  r := r || jsonb_build_object('TC-SB646-01.skills', case when bad is null then 'pass' else 'FAIL: ' || bad end);

  -- the approval gate's refusal is guidance too: agents read it when they are refused
  msg := substring(pg_get_functiondef('public.enforce_approval_gate'::regproc) from 'RAISE EXCEPTION ''([^'']*)''');
  r := r || jsonb_build_object('TC-SB646-01.approval_gate_message',
         case when msg like '%an L0/L1 ticket stays where it is with a comment for its PM%' and pg_temp.unscoped(msg) = 0
                   and msg not like '%Set approval_status=approved%'
              then 'pass' else 'FAIL: ' || coalesce(msg, 'no message') end);

  -- TC-SB646-01: the pinned SB-646 edits
  select count(*) into n from public.work_items w, jsonb_array_elements(w.meta->'rollback_agent_edits')
  where w.ticket_code = 'SB-646';
  r := r || jsonb_build_object('TC-SB646-01.sixteen_agent_edits', case when n = 16 then 'pass' else 'FAIL: ' || n end);
  select count(*) into n from public.work_items w, jsonb_array_elements(w.meta->'rollback_other_edits')
  where w.ticket_code = 'SB-646';
  r := r || jsonb_build_object('TC-SB646-01.two_other_edits', case when n = 2 then 'pass' else 'FAIL: ' || n end);
  bad := null;
  for e in select coalesce(x->>'table', 'agents') tbl, coalesce(x->>'agent_id', x->>'skill_id', x->>'id') rid,
                  coalesce(x->>'agent', x->>'skill_id', x->>'id') label, x->>'field' field, x->>'new' new_t, x->>'old' old_t
           from public.work_items w,
                jsonb_array_elements(coalesce(w.meta->'rollback_agent_edits', '[]') || coalesce(w.meta->'rollback_other_edits', '[]')) x
           where w.ticket_code = 'SB-646'
  loop
    live := pg_temp.field(e.tbl, e.rid, e.field);
    if live is null
       or (length(live) - length(replace(live, e.new_t, ''))) / length(e.new_t) <> 1
       or position(e.old_t in live) > 0
       -- the runbook edit corrects the reopen rule, not awaiting_jason scoping; TC-SB646-03 proves it
       or (e.tbl <> 'reference_items' and pg_temp.unscoped(replace(live, e.new_t, e.old_t)) <= pg_temp.unscoped(live)) then
      bad := concat_ws(', ', bad, e.label || '/' || e.field);
    end if;
  end loop;
  r := r || jsonb_build_object('TC-SB646-01.each_edit_once_and_needed', case when bad is null then 'pass' else 'FAIL: ' || bad end);

  -- TC-SB646-03: an L1 ticket cannot be parked on Jason
  t1 := pg_temp.mk('ZZH-1', 1, 'todo');
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason' where id = %L$q$, t1));
  r := r || jsonb_build_object('TC-SB646-03.l1_refused',
         case when st = 'SB-644' and (select status from public.work_items where id = t1) = 'todo' then 'pass' else 'FAIL: ' || st end);

  -- the same write, raised to L2 in the same update as the guidance says, goes through
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason', authority_level = 2 where id = %L$q$, t1));
  r := r || jsonb_build_object('TC-SB646-03.raised_to_l2_enters',
         case when st = 'ok' and (select status || ':' || authority_level from public.work_items where id = t1) = 'awaiting_jason:2'
              then 'pass' else 'FAIL: ' || st end);

  -- the other path: leave the L1 ticket where it is, with a comment for its PM
  t2 := pg_temp.mk('ZZH-2', 1, 'todo');
  st := pg_temp.t(format($q$insert into public.work_item_comments (work_item_id, user_id, body)
                            values (%L, %L, '[qa-sb646] needs a PM decision; left in place')$q$, t2, ub));
  r := r || jsonb_build_object('TC-SB646-03.leave_in_place_with_comment',
         case when st = 'ok'
                   and (select status || ':' || authority_level from public.work_items where id = t2) = 'todo:1'
                   and (select count(*) from public.work_item_comments where work_item_id = t2) = 1
              then 'pass' else 'FAIL: ' || st end);

  -- the cancellation runbook's new sentence: Jason reopens an L1 ticket he rejected to todo, not to awaiting_jason
  t3 := pg_temp.mk('ZZH-3', 1, 'todo');
  st := pg_temp.t(format($q$update public.work_items set status = 'cancelled', cancel_reason = 'rejected_by_jason',
                              cancel_note = 'qa-sb646 fixture', cancelled_by = 'Jason Paulsen' where id = %L$q$, t3));
  t4 := pg_temp.mk('ZZH-4', 1, 'todo');
  st := st || '/' || pg_temp.t(format($q$update public.work_items set status = 'cancelled', cancel_reason = 'rejected_by_jason',
                              cancel_note = 'qa-sb646 fixture', cancelled_by = 'Jason Paulsen' where id = %L$q$, t4));
  r := r || jsonb_build_object('TC-SB646-03.fixtures_cancelled', case when st = 'ok/ok' then 'pass' else 'FAIL: ' || st end);
  st := pg_temp.t(format($q$update public.work_items set status = 'todo', meta = coalesce(meta, '{}') || '{"reopened_by": "Jason Paulsen"}'
                            where id = %L$q$, t3));
  r := r || jsonb_build_object('TC-SB646-03.jason_reopens_l1_to_todo',
         case when st = 'ok' and (select status from public.work_items where id = t3) = 'todo' then 'pass' else 'FAIL: ' || st end);
  st := pg_temp.t(format($q$update public.work_items set status = 'awaiting_jason', meta = coalesce(meta, '{}') || '{"reopened_by": "Jason Paulsen"}'
                            where id = %L$q$, t4));
  r := r || jsonb_build_object('TC-SB646-03.l1_reopen_to_awaiting_refused',
         case when st = 'SB-644' and (select status from public.work_items where id = t4) = 'cancelled' then 'pass' else 'FAIL: ' || st end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'AGENT_GOVERNANCE_GUIDANCE PASS (% checks) %', (select count(*) from jsonb_object_keys(r)), r;
  else
    raise exception 'AGENT_GOVERNANCE_GUIDANCE FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)), r;
  end if;
end
$suite$;
