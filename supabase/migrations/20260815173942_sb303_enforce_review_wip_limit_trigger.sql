
-- SB-303: Trigger to enforce per-project review-stage WIP limits
CREATE OR REPLACE FUNCTION enforce_review_wip_limit()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_limit INTEGER;
  v_count INTEGER;
  v_ticket_code TEXT;
  v_project_name TEXT;
BEGIN
  -- Only fire on transition INTO review
  IF NEW.status IS DISTINCT FROM 'review' THEN
    RETURN NEW;
  END IF;

  -- For UPDATE, skip if already in review (not a transition)
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'review' THEN
    RETURN NEW;
  END IF;

  -- Look up the project's review_wip_limit
  SELECT p.review_wip_limit, p.name INTO v_limit, v_project_name
  FROM projects p
  WHERE p.id = NEW.project_id;

  -- NULL = unlimited, skip
  IF v_limit IS NULL THEN
    RETURN NEW;
  END IF;

  -- Exemption: Jason Paulsen
  IF NEW.assignee = 'Jason Paulsen' THEN
    RETURN NEW;
  END IF;

  -- Exemption: wip_override flag
  IF (NEW.meta->>'wip_override') = 'true' THEN
    RETURN NEW;
  END IF;

  -- Count current review items for this project (exclude self)
  SELECT COUNT(*) INTO v_count
  FROM work_items
  WHERE project_id = NEW.project_id
    AND status = 'review'
    AND id IS DISTINCT FROM NEW.id;

  -- When at or over limit: redirect to on_hold
  IF v_count >= v_limit THEN
    v_ticket_code := COALESCE(NEW.ticket_code, NEW.id::text);

    NEW.status := 'on_hold';

    NEW.meta := COALESCE(NEW.meta, '{}'::jsonb) || jsonb_build_object(
      'hold_reason', 'review_wip_limit',
      'review_wip_blocked_at', now()::text,
      'review_wip_project', v_project_name,
      'review_wip_count', v_count,
      'review_wip_limit', v_limit
    );

    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (
        NEW.project_id,
        NEW.user_id,
        'System',
        'updated',
        'work_items',
        NEW.id,
        format('Review WIP limit reached: %s redirected to on_hold. Project %s has %s/%s items in review.',
               v_ticket_code, v_project_name, v_count, v_limit),
        jsonb_build_object(
          'trigger', 'enforce_review_wip_limit',
          'event', 'review_wip_blocked',
          'ticket_code', v_ticket_code,
          'project', v_project_name,
          'review_count', v_count,
          'review_limit', v_limit
        )
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enforce_review_wip_limit: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$;

-- Create trigger (fire BEFORE so we can redirect status)
CREATE TRIGGER trg_enforce_review_wip_limit
  BEFORE INSERT OR UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_review_wip_limit();
;
