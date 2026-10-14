CREATE OR REPLACE FUNCTION public.log_assignee_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- SB-371: work_items.assignee is plain text with no history and no FK, so an
  -- overwrite used to leave no trace at all. That made a whole class of ticket
  -- unverifiable: anything whose deliverable is "route X to Y" reads as
  -- unproven the moment the assignee legitimately moves on. CIP-116 is the
  -- worked example -- its Tauri-scaffold leg could be neither confirmed nor
  -- refuted, and CIP-TC-030 had to be recorded blocked for that reason.
  --
  -- activity_log already carries status moves, so reassignments are recorded
  -- in the same place, the same way, and show up in the same board history.
  BEGIN
    INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
    VALUES (
      NEW.project_id,
      NEW.user_id,
      'System',
      'updated',  -- activity_log_action_check permits no narrower verb
      'work_items',
      NEW.id,
      format('%s reassigned: %s -> %s',
             COALESCE(NEW.ticket_code, NEW.id::text),
             COALESCE(OLD.assignee, '(unassigned)'),
             COALESCE(NEW.assignee, '(unassigned)')),
      jsonb_build_object(
        'trigger', 'log_assignee_change',
        'event', 'assignee_changed',
        'ticket_code', NEW.ticket_code,
        'from', OLD.assignee,
        'to', NEW.assignee,
        'status', NEW.status
      )
    );
  EXCEPTION WHEN OTHERS THEN
    -- Same posture as enforce_wip_limit: a logging failure must never block the
    -- write it was only meant to describe.
    RAISE WARNING 'log_assignee_change: activity_log insert failed: %', SQLERRM;
  END;

  RETURN NULL;  -- AFTER trigger; return value is ignored
END;
$function$;

-- Deliberately NOT "AFTER UPDATE OF assignee". That form keys off the columns
-- named in the SET clause, so a reassignment performed by a BEFORE trigger --
-- enforce_review_assignee auto-assigning a reviewer on a status-only update --
-- would never fire it. A plain AFTER UPDATE with a WHEN clause is evaluated
-- against the final NEW row, so it catches those too.
DROP TRIGGER IF EXISTS trg_log_assignee_change ON public.work_items;
CREATE TRIGGER trg_log_assignee_change
  AFTER UPDATE ON public.work_items
  FOR EACH ROW
  WHEN (OLD.assignee IS DISTINCT FROM NEW.assignee)
  EXECUTE FUNCTION public.log_assignee_change();

COMMENT ON FUNCTION public.log_assignee_change() IS
'SB-371: records every work_items.assignee change as an activity_log row (action=updated, meta.event=assignee_changed, meta.from/to), so routing deliverables stay verifiable after the assignee moves on. Fires from an AFTER UPDATE ... WHEN trigger so BEFORE-trigger reassignments are captured as well.';;
