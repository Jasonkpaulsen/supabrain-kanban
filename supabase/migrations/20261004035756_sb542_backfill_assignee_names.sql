-- SB-542: one-time backfill of work_items.assignee for legacy rows that carry an
-- assigned_agent_id but no assignee name (49 on 2026-10-04; 47 done, 1 backlog,
-- 1 on_hold). All were created 2026-05-08..07-11, before sb328_assignee_integrity
-- (2026-08-11), whose trigger now derives the name on every insert, so no new row
-- can arrive in this state. This only fills the name from the agent the row
-- already points at.
--
-- Expected side effects (SB-542 acceptance 3): trg_log_assignee_change writes one
-- activity_log row per backfilled item (meta.event = 'assignee_changed', from the
-- empty value to the agent's name), and updated_at moves. Status, assigned_agent_id
-- and completed_at are unchanged; the block below asserts it.

do $mig$
declare
  v_ids    uuid[];
  v_before jsonb;
  v_n      int;
  n        int;
begin
  select array_agg(w.id),
         jsonb_object_agg(w.id, jsonb_build_object('status', w.status, 'agent', w.assigned_agent_id,
                                                   'completed_at', w.completed_at))
    into v_ids, v_before
    from public.work_items w
   where w.assigned_agent_id is not null and coalesce(w.assignee, '') = '';
  v_n := coalesce(array_length(v_ids, 1), 0);

  update public.work_items w
     set assignee = a.name
    from public.agents a
   where a.id = w.assigned_agent_id and w.id = any(v_ids);

  -- A1: no row has an agent id without a name
  select count(*) into n from public.work_items w
   where w.assigned_agent_id is not null and coalesce(w.assignee, '') = '';
  if n <> 0 then raise exception 'A1: % row(s) still have an agent id and no name', n; end if;

  -- A2: every backfilled name is its agent's name
  select count(*) into n from public.work_items w join public.agents a on a.id = w.assigned_agent_id
   where w.id = any(v_ids) and w.assignee is distinct from a.name;
  if n <> 0 then raise exception 'A2: % backfilled name(s) do not match the agent', n; end if;

  -- A3: nothing else moved
  select count(*) into n from public.work_items w
   where w.id = any(v_ids)
     and (w.status is distinct from v_before->(w.id::text)->>'status'
          or w.assigned_agent_id::text is distinct from v_before->(w.id::text)->>'agent'
          or w.completed_at is distinct from (v_before->(w.id::text)->>'completed_at')::timestamptz);
  if n <> 0 then raise exception 'A3: % row(s) changed status, agent or completion', n; end if;

  -- A4: one assignee_changed activity row per backfilled item
  select count(*) into n from public.activity_log l
   where l.target_table = 'work_items' and l.target_id = any(v_ids)
     and l.meta->>'event' = 'assignee_changed' and l.created_at >= now();
  if n <> v_n then raise exception 'A4: expected % activity row(s), found %', v_n, n; end if;

  raise notice 'SB-542: backfilled % row(s)', v_n;
end $mig$;
