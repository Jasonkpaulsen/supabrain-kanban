-- SB-646 (option A): agent guidance matches SB-644 (ADR-GOV-001-A2). TC-SB646-01, -03.
--
-- Run as postgres. One transaction that always ends by raising, so no fixture survives.
-- Pass = the raised message starts with "AGENT_GOVERNANCE_GUIDANCE PASS".
--
-- TC-SB646-01 reads the live agent text. Every sentence in a non-archived agent that mentions
-- awaiting_jason must scope it to L2+ work: name L3/L4 or L2+, tell the agent to raise
-- authority_level to 2 or higher, or be a read-only query of the queue. The 16 SB-646 edits are
-- pinned from SB-646 meta.rollback_agent_edits: each new text is present exactly once, the old
-- text is gone, and putting the old text back makes the checker fail (so every edit is needed
-- and the checker can see the difference).
-- TC-SB646-03 exercises the database behaviour the guidance tells agents to rely on. Fixtures use
-- ticket codes outside every project's numbering (ZZH-*), have no assignee (no WIP gate) and use
-- approval_status not_required. Every step with a side effect runs on its own line, in order.

do $suite$
declare
  ub constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  r jsonb := '{}'::jsonb; fails int; st text; n int; bad text;
  e record; live text; t1 uuid; t2 uuid;
begin
  -- number of sentences in a text that send work to awaiting_jason without scoping it to L2+
  execute $f$create function pg_temp.unscoped(txt text) returns int language sql immutable as $b$
    select count(*)::int from regexp_split_to_table(coalesce(txt, ''), '(\.\s|;\s|\n|\\n)') s
    where s ilike '%awaiting_jason%'
      and s !~* '(L3/L4|L2\+|authority_level (2 or higher|to at least 2)|at authority_level 2|select )' $b$$f$;
  execute $f$create function pg_temp.field(a public.agents, k text) returns text language sql stable as $b$
    select case k when 'system_prompt' then a.system_prompt
                  when 'constraints' then array_to_string(a.constraints, E'\n')
                  when 'meta' then a.meta::text end $b$$f$;
  execute $f$create function pg_temp.t(q text) returns text language plpgsql as $b$
    begin execute q; return 'ok';
    exception when others then return case when sqlerrm like 'GOV-001 (SB-644)%' then 'SB-644'
                                         when sqlerrm like 'GOV-001%' then 'GOV-001'
                                         else sqlstate || ': ' || left(sqlerrm, 80) end;
    end $b$$f$;
  execute $f$create function pg_temp.mk(code text, lvl int, st text) returns uuid language sql as $b$
    insert into public.work_items (project_id, user_id, ticket_code, title, type, status, priority, approval_status, authority_level)
    values ((select id from public.projects where project_key = 'SB'), '5ecbd44a-a3e2-4363-9133-dff3851ba0f5', code,
            'qa-sb646 ' || code, 'task', st, 'low', 'not_required', lvl) returning id $b$$f$;

  -- TC-SB646-01: the checker itself
  r := r || jsonb_build_object('TC-SB646-01.checker_flags_unscoped',
         case when pg_temp.unscoped('Escalate to Jason via awaiting_jason. Done.') = 1
                   and pg_temp.unscoped('When in doubt, awaiting_jason') = 1
                   and pg_temp.unscoped('For L3/L4 items use status=''awaiting_jason''. Use status=awaiting_jason, set authority_level to at least 2') = 0
              then 'pass' else 'FAIL' end);

  -- TC-SB646-01: no live agent sends unscoped work to awaiting_jason
  select string_agg(a.name || '/' || f.k, ', ' order by a.name, f.k) into bad
  from public.agents a
  cross join lateral (values ('system_prompt', a.system_prompt), ('description', a.description),
                             ('constraints', array_to_string(a.constraints, E'\n')), ('goals', array_to_string(a.goals, E'\n')),
                             ('escalation_rules', a.escalation_rules::text), ('priority_rules', a.priority_rules::text),
                             ('auto_assign_rules', a.auto_assign_rules::text), ('trigger_config', a.trigger_config::text),
                             ('meta', a.meta::text)) f(k, v)
  where a.user_id = ub and a.status <> 'archived' and pg_temp.unscoped(f.v) > 0;
  r := r || jsonb_build_object('TC-SB646-01.no_unscoped_awaiting_jason', case when bad is null then 'pass' else 'FAIL: ' || bad end);

  -- the checker has something to look at: the active agents still mention awaiting_jason
  select count(*) into n from public.agents a
  where a.user_id = ub and a.status <> 'archived'
    and concat_ws(' ', a.system_prompt, array_to_string(a.constraints, ' '), a.escalation_rules::text, a.meta::text) ilike '%awaiting_jason%';
  r := r || jsonb_build_object('TC-SB646-01.coverage', case when n >= 30 then 'pass' else 'FAIL: ' || n end);

  -- TC-SB646-01: the 16 SB-646 edits
  select count(*) into n from public.work_items w, jsonb_array_elements(w.meta->'rollback_agent_edits')
  where w.ticket_code = 'SB-646';
  r := r || jsonb_build_object('TC-SB646-01.sixteen_edits', case when n = 16 then 'pass' else 'FAIL: ' || n end);
  bad := null;
  for e in select x->>'agent_id' agent_id, x->>'agent' agent, x->>'field' field, x->>'new' new_t, x->>'old' old_t
           from public.work_items w, jsonb_array_elements(w.meta->'rollback_agent_edits') x
           where w.ticket_code = 'SB-646'
  loop
    select pg_temp.field(a, e.field) into live from public.agents a where a.id = e.agent_id::uuid;
    if live is null
       or (length(live) - length(replace(live, e.new_t, ''))) / length(e.new_t) <> 1
       or position(e.old_t in live) > 0
       or pg_temp.unscoped(replace(live, e.new_t, e.old_t)) <= pg_temp.unscoped(live) then
      bad := concat_ws(', ', bad, e.agent || '/' || e.field);
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

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'AGENT_GOVERNANCE_GUIDANCE PASS (% checks) %', (select count(*) from jsonb_object_keys(r)), r;
  else
    raise exception 'AGENT_GOVERNANCE_GUIDANCE FAIL (% of % checks) %', fails, (select count(*) from jsonb_object_keys(r)), r;
  end if;
end
$suite$;
