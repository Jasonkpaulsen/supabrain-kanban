
-- SB-394: the gates set the column, and documentation stops being blocked.
--
-- The exemption exists because work that is already FINISHED could not be written
-- down: SB-379..382 were redirected to on_hold at creation, and SB-387 had to be
-- back-filled as done after the fact. A retro-documentation ticket carries no
-- review load, so it must not consume review WIP.
create or replace function public.enforce_review_wip_limit()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  v_limit INTEGER;
  v_count INTEGER;
  v_ticket_code TEXT;
  v_project_name TEXT;
BEGIN
  IF NEW.status IS DISTINCT FROM 'review' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'review' THEN RETURN NEW; END IF;

  SELECT p.review_wip_limit, p.name INTO v_limit, v_project_name
  FROM projects p WHERE p.id = NEW.project_id;
  IF v_limit IS NULL THEN RETURN NEW; END IF;

  IF NEW.assignee = 'Jason Paulsen' THEN RETURN NEW; END IF;
  IF (NEW.meta->>'wip_override') = 'true' THEN RETURN NEW; END IF;

  -- SB-394 exemption: documentation and test-case tickets carry no review load.
  IF NEW.action_category IN ('documentation','test_execution') THEN RETURN NEW; END IF;

  SELECT COUNT(*) INTO v_count FROM work_items
   WHERE project_id = NEW.project_id AND status = 'review' AND id IS DISTINCT FROM NEW.id;

  IF v_count >= v_limit THEN
    v_ticket_code := COALESCE(NEW.ticket_code, NEW.id::text);
    NEW.status       := 'on_hold';
    NEW.held_by_gate := 'enforce_review_wip_limit';
    NEW.hold_reason  := NULL;
    NEW.meta := COALESCE(NEW.meta,'{}'::jsonb) || jsonb_build_object(
      'review_wip_blocked_at', now()::text, 'review_wip_project', v_project_name,
      'review_wip_count', v_count, 'review_wip_limit', v_limit);

    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (NEW.project_id, NEW.user_id, 'System', 'updated', 'work_items', NEW.id,
        format('Review WIP limit reached: %s redirected to on_hold. Project %s has %s/%s items in review.',
               v_ticket_code, v_project_name, v_count, v_limit),
        jsonb_build_object('trigger','enforce_review_wip_limit','event','review_wip_blocked',
          'ticket_code',v_ticket_code,'project',v_project_name,'review_count',v_count,'review_limit',v_limit));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enforce_review_wip_limit: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

create or replace function public.enforce_wip_limit()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  v_limit INTEGER;
  v_count INTEGER;
  v_ticket_code TEXT;
BEGIN
  IF NEW.status IS DISTINCT FROM 'in_progress' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'in_progress' THEN RETURN NEW; END IF;
  IF NEW.assignee IS NULL THEN RETURN NEW; END IF;
  IF NEW.assignee = 'Jason Paulsen' THEN RETURN NEW; END IF;
  IF (NEW.meta->>'wip_override') = 'true' THEN RETURN NEW; END IF;

  SELECT wl.max_wip INTO v_limit FROM wip_limits wl WHERE wl.assignee = NEW.assignee;
  IF v_limit IS NULL THEN
    SELECT a.max_concurrent_tasks INTO v_limit FROM agents a
     WHERE a.name = NEW.assignee AND a.user_id = NEW.user_id;
  END IF;
  IF v_limit IS NULL THEN v_limit := 5; END IF;

  SELECT COUNT(*) INTO v_count FROM work_items
   WHERE user_id = NEW.user_id AND assignee = NEW.assignee
     AND status = 'in_progress' AND id IS DISTINCT FROM NEW.id;

  IF v_count >= v_limit THEN
    v_ticket_code := COALESCE(NEW.ticket_code, NEW.id::text);
    NEW.status       := 'on_hold';
    NEW.held_by_gate := 'enforce_wip_limit';
    NEW.hold_reason  := NULL;
    NEW.meta := COALESCE(NEW.meta,'{}'::jsonb) || jsonb_build_object(
      'wip_blocked_at', now()::text, 'wip_blocked_assignee', NEW.assignee,
      'wip_blocked_count', v_count, 'wip_blocked_limit', v_limit);

    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (NEW.project_id, NEW.user_id, 'System', 'updated', 'work_items', NEW.id,
        format('WIP limit reached: %s redirected to on_hold. Assignee %s has %s/%s in-progress tickets.',
               v_ticket_code, NEW.assignee, v_count, v_limit),
        jsonb_build_object('trigger','enforce_wip_limit','event','wip_blocked',
          'ticket_code',v_ticket_code,'assignee',NEW.assignee,'wip_count',v_count,'wip_limit',v_limit));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enforce_wip_limit: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;
;
