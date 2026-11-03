
-- SB-267: Slot-open notification trigger (notify_wip_slot_opened)
-- AFTER UPDATE trigger — fires when ticket transitions OUT of in_progress
-- Audit trail only — does NOT auto-promote tickets

CREATE OR REPLACE FUNCTION notify_wip_slot_opened()
RETURNS TRIGGER AS $$
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

  -- Check for queued on_hold tickets with hold_reason = 'wip_limit' for this assignee
  FOR v_queued IN
    SELECT ticket_code, title, priority, meta->>'wip_blocked_at' AS blocked_at
    FROM work_items
    WHERE user_id = OLD.user_id
      AND status = 'on_hold'
      AND meta->>'hold_reason' = 'wip_limit'
      AND meta->>'wip_blocked_assignee' = v_assignee
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
$$ LANGUAGE plpgsql;

-- Create AFTER UPDATE trigger
CREATE TRIGGER trg_notify_wip_slot_opened
  AFTER UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION notify_wip_slot_opened();
;
