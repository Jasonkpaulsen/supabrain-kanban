-- SB-598: the WIP queue reads the column the gate writes (ADR-FLOW-005 D10, pkg-4).
--
-- Since sb394 enforce_wip_limit parks a ticket as status = 'on_hold' with
-- held_by_gate = 'enforce_wip_limit' and no longer writes the meta marker that
-- notify_wip_slot_opened and the pm-triage-dispatch Step 4a still filtered on.
-- 1. New view v_wip_queue (security invoker): the one query both consumers share.
-- 2. notify_wip_slot_opened: same body, queued-ticket predicate now reads held_by_gate
--    and the live assignee column.
-- No data is rewritten: 0 tickets are parked; the 23 stale wip_blocked_* meta rows stay as history.
-- enforce_wip_limit and trg_notify_wip_slot_opened are read-only here and asserted below.

create or replace view public.v_wip_queue
with (security_invoker = true) as
select
  w.id,
  w.user_id,
  w.project_id,
  w.ticket_code,
  w.title,
  w.priority,
  w.assignee,
  b.blocked_at,
  now() - b.blocked_at as queue_age,
  c.current_wip,
  l.wip_limit,
  c.current_wip < l.wip_limit as slot_available
from public.work_items w
cross join lateral (
  select case when pg_input_is_valid(w.meta->>'wip_blocked_at', 'timestamptz')
              then (w.meta->>'wip_blocked_at')::timestamptz end as blocked_at
) b
cross join lateral (
  select count(*)::int as current_wip
    from public.work_items x
   where x.user_id = w.user_id
     and x.assignee = w.assignee
     and x.status = 'in_progress'
     and x.archived is not true
) c
cross join lateral (
  -- Same resolution order as enforce_wip_limit: wip_limits by assignee,
  -- then agents.max_concurrent_tasks for the same user, then 5.
  select coalesce(
           (select wl.max_wip from public.wip_limits wl where wl.assignee = w.assignee limit 1),
           (select a.max_concurrent_tasks from public.agents a
             where a.name = w.assignee and a.user_id = w.user_id limit 1),
           5) as wip_limit
) l
where w.status = 'on_hold'
  and w.held_by_gate = 'enforce_wip_limit'
  and w.archived is not true;

comment on view public.v_wip_queue is
  'SB-598 / ADR-FLOW-005 D10: tickets parked by enforce_wip_limit (status on_hold, held_by_gate enforce_wip_limit), with the limit resolved as the gate does. Read by pm-triage-dispatch Step 4a and the supabrain-sweep wip_queue op.';

revoke all on public.v_wip_queue from public, anon, authenticated, service_role;
grant select on public.v_wip_queue to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.notify_wip_slot_opened()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_assignee TEXT;
  v_count INTEGER;
  v_limit INTEGER;
  v_queued RECORD;
  v_queued_list TEXT := '';
  v_queued_count INTEGER := 0;
BEGIN
  -- Only fire when transitioning OUT of in_progress
  IF OLD.status IS DISTINCT FROM 'in_progress' THEN
    RETURN NEW;
  END IF;
  IF NEW.status IS NOT DISTINCT FROM 'in_progress' THEN
    RETURN NEW;
  END IF;

  v_assignee := OLD.assignee;

  -- If no assignee, nothing to check
  IF v_assignee IS NULL THEN
    RETURN NEW;
  END IF;

  -- Count current in_progress for this assignee (post-transition, row already updated)
  SELECT COUNT(*) INTO v_count
  FROM work_items
  WHERE user_id = OLD.user_id
    AND assignee = v_assignee
    AND status = 'in_progress';

  -- Resolve limit (same priority as enforce_wip_limit)
  SELECT wl.max_wip INTO v_limit
  FROM wip_limits wl
  WHERE wl.assignee = v_assignee;

  IF v_limit IS NULL THEN
    SELECT a.max_concurrent_tasks INTO v_limit
    FROM agents a
    WHERE a.name = v_assignee
      AND a.user_id = OLD.user_id;
  END IF;

  IF v_limit IS NULL THEN
    v_limit := 5;
  END IF;

  -- Only notify if assignee now has capacity (below limit)
  IF v_count >= v_limit THEN
    RETURN NEW;
  END IF;

  -- SB-598: queued tickets are the ones enforce_wip_limit parked for this live assignee
  FOR v_queued IN
    SELECT ticket_code, title, priority, meta->>'wip_blocked_at' AS blocked_at
    FROM work_items
    WHERE user_id = OLD.user_id
      AND status = 'on_hold'
      AND held_by_gate = 'enforce_wip_limit'
      AND assignee = v_assignee
      AND archived IS NOT TRUE
    ORDER BY
      CASE priority
        WHEN 'critical' THEN 1
        WHEN 'high' THEN 2
        WHEN 'medium' THEN 3
        WHEN 'low' THEN 4
        ELSE 5
      END,
      (meta->>'wip_blocked_at')::timestamptz ASC NULLS LAST
  LOOP
    v_queued_count := v_queued_count + 1;
    IF v_queued_list <> '' THEN
      v_queued_list := v_queued_list || ', ';
    END IF;
    v_queued_list := v_queued_list || format('%s (%s, %s)',
      COALESCE(v_queued.ticket_code, '?'),
      COALESCE(v_queued.title, 'untitled'),
      COALESCE(v_queued.priority, 'unset'));
  END LOOP;

  -- If queued tickets exist, log the notification
  IF v_queued_count > 0 THEN
    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (
        OLD.project_id,
        OLD.user_id,
        'System',
        'updated',
        'work_items',
        OLD.id,
        format('WIP slot opened: %s now has %s/%s in-progress. %s queued ticket(s) waiting: %s',
               v_assignee, v_count, v_limit, v_queued_count, v_queued_list),
        jsonb_build_object(
          'trigger', 'notify_wip_slot_opened',
          'event', 'wip_slot_opened',
          'assignee', v_assignee,
          'current_wip', v_count,
          'wip_limit', v_limit,
          'queued_count', v_queued_count,
          'queued_tickets', v_queued_list,
          'source_ticket', COALESCE(OLD.ticket_code, OLD.id::text)
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'notify_wip_slot_opened: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

do $assert$
declare
  src text; n int;
begin
  select p.prosrc into src from pg_proc p where p.oid = 'public.notify_wip_slot_opened()'::regprocedure;
  if position('held_by_gate' in src) = 0 or position('hold_reason' in src) > 0 then
    raise exception 'SB-598 assert: notify_wip_slot_opened predicate not switched to held_by_gate';
  end if;
  select count(*) into n from pg_proc p
   where p.oid = 'public.notify_wip_slot_opened()'::regprocedure
     and not p.prosecdef and p.proconfig @> array['search_path=public'];
  if n <> 1 then raise exception 'SB-598 assert: notify_wip_slot_opened posture changed'; end if;

  select p.prosrc into src from pg_proc p where p.oid = 'public.enforce_wip_limit()'::regprocedure;
  if position('held_by_gate := ''enforce_wip_limit''' in src) = 0 then
    raise exception 'SB-598 assert: enforce_wip_limit no longer assigns held_by_gate';
  end if;

  select count(*) into n from pg_trigger t
   where t.tgrelid = 'public.work_items'::regclass and t.tgname = 'trg_notify_wip_slot_opened'
     and t.tgenabled = 'O' and t.tgfoid = 'public.notify_wip_slot_opened()'::regprocedure;
  if n <> 1 then raise exception 'SB-598 assert: trg_notify_wip_slot_opened missing or not enabled'; end if;

  select count(*) into n from pg_class c
   where c.oid = 'public.v_wip_queue'::regclass and c.relkind = 'v'
     and c.reloptions @> array['security_invoker=true']
     and not has_table_privilege('anon', c.oid, 'select')
     and has_table_privilege('authenticated', c.oid, 'select')
     and has_table_privilege('service_role', c.oid, 'select');
  if n <> 1 then raise exception 'SB-598 assert: v_wip_queue missing, not security_invoker, or grants wrong'; end if;

  select count(*) into n from (
    select string_agg(a.attname, ',' order by a.attnum) cols from pg_attribute a
     where a.attrelid = 'public.v_wip_queue'::regclass and a.attnum > 0) x
   where x.cols = 'id,user_id,project_id,ticket_code,title,priority,assignee,blocked_at,queue_age,current_wip,wip_limit,slot_available';
  if n <> 1 then raise exception 'SB-598 assert: v_wip_queue column list differs from the contract'; end if;

  perform count(*) from public.v_wip_queue;
end
$assert$;
