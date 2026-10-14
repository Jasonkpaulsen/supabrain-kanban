
-- SB-377: the review WIP limit becomes per-reviewer.
--
-- ORDERING IS THE WHOLE FIX. Postgres fires BEFORE triggers in alphabetical order,
-- and `trg_enforce_review_wip_limit` sorted ahead of `trg_review_assignee` — so the
-- limit was checked before a reviewer had been chosen. That is why it could only
-- ever count per-project. Renamed to trg_zy_* so it runs after routing (and before
-- trg_zz_clear_hold_marker, which must stay last).
--
-- Limit resolution: the reviewer's own max_concurrent_tasks, else the project's
-- review_wip_limit, else 5. The project column keeps meaning as a default for
-- reviewers that set no capacity of their own.
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
  IF NEW.assignee IS NULL THEN RETURN NEW; END IF;

  IF NEW.assignee = 'Jason Paulsen' THEN RETURN NEW; END IF;
  IF (NEW.meta->>'wip_override') = 'true' THEN RETURN NEW; END IF;
  -- SB-394: documentation and test-case tickets carry no review load.
  IF NEW.action_category IN ('documentation','test_execution') THEN RETURN NEW; END IF;

  SELECT p.name INTO v_project_name FROM projects p WHERE p.id = NEW.project_id;

  -- Per-reviewer capacity, with the project setting as the fallback default.
  SELECT a.max_concurrent_tasks INTO v_limit
    FROM agents a WHERE a.id = NEW.assigned_agent_id;
  IF v_limit IS NULL THEN
    SELECT p.review_wip_limit INTO v_limit FROM projects p WHERE p.id = NEW.project_id;
  END IF;
  IF v_limit IS NULL THEN v_limit := 5; END IF;

  -- Count what THIS REVIEWER holds, across projects: a reviewer's attention is not
  -- partitioned by project, and the old per-project count let one agent be the
  -- bottleneck in several lanes at once without any of them noticing.
  SELECT COUNT(*) INTO v_count
  FROM work_items
   WHERE assignee = NEW.assignee AND status = 'review'
     AND NOT archived AND id IS DISTINCT FROM NEW.id;

  IF v_count >= v_limit THEN
    v_ticket_code := COALESCE(NEW.ticket_code, NEW.id::text);
    NEW.status       := 'on_hold';
    NEW.held_by_gate := 'enforce_review_wip_limit';
    NEW.hold_reason  := NULL;
    NEW.meta := COALESCE(NEW.meta,'{}'::jsonb) || jsonb_build_object(
      'review_wip_blocked_at', now()::text,
      'review_wip_reviewer', NEW.assignee,
      'review_wip_count', v_count, 'review_wip_limit', v_limit);

    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (NEW.project_id, NEW.user_id, 'System', 'updated', 'work_items', NEW.id,
        format('Review WIP limit reached: %s redirected to on_hold. Reviewer %s holds %s/%s items in review.',
               v_ticket_code, NEW.assignee, v_count, v_limit),
        jsonb_build_object('trigger','enforce_review_wip_limit','event','review_wip_blocked',
          'ticket_code',v_ticket_code,'project',v_project_name,'reviewer',NEW.assignee,
          'review_count',v_count,'review_limit',v_limit));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'enforce_review_wip_limit: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$function$;

drop trigger if exists trg_enforce_review_wip_limit on public.work_items;
create trigger trg_zy_review_wip_limit
  before insert or update on public.work_items
  for each row execute function public.enforce_review_wip_limit();
;
