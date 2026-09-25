
-- SB-286: Enforce reviewer assignment on transition to review.
-- If a ticket moves to 'review' with no assignee, auto-assign the project's
-- Architect agent. If no Architect agent is found for the project, block the transition.

CREATE OR REPLACE FUNCTION public.enforce_review_assignee()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path TO 'public'
AS $function$
DECLARE
  v_architect_id   uuid;
  v_architect_name text;
BEGIN
  -- Only act on transitions INTO 'review'
  IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN

    -- If assignee is already set (either text or agent_id), allow
    IF NEW.assigned_agent_id IS NOT NULL OR (NEW.assignee IS NOT NULL AND NEW.assignee != '') THEN
      RETURN NEW;
    END IF;

    -- Look up the project's Architect agent
    SELECT a.id, a.name
      INTO v_architect_id, v_architect_name
      FROM agents a
      JOIN agent_projects ap ON ap.agent_id = a.id AND ap.project_id = NEW.project_id
     WHERE a.name ILIKE '%Architect%'
     LIMIT 1;

    IF v_architect_id IS NOT NULL THEN
      -- Auto-assign the Architect
      NEW.assigned_agent_id := v_architect_id;
      NEW.assignee          := v_architect_name;
      NEW.meta := jsonb_set(
        coalesce(NEW.meta, '{}'),
        '{review_auto_assigned}',
        to_jsonb(format('SB-286: auto-assigned %s as reviewer on %s', v_architect_name, now()::text))
      );
    ELSE
      -- No Architect found — block the transition
      RAISE EXCEPTION 'SB-286: Cannot move to review without a reviewer. '
        'No Architect agent is assigned to project %. '
        'Set assignee or assigned_agent_id before moving to review.',
        NEW.project_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- Fire BEFORE the review SLA tracker so the assignee is set before timestamps are recorded
CREATE TRIGGER trg_review_assignee
  BEFORE UPDATE ON public.work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_review_assignee();

COMMENT ON FUNCTION public.enforce_review_assignee() IS
  'SB-286: Ensures every ticket entering review status has a reviewer assigned. '
  'Auto-assigns the project Architect agent if no assignee is set. '
  'Blocks transition if no Architect agent exists for the project.';
;
