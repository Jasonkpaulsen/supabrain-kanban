
-- SB-377: reviewer routing picks the least-loaded eligible reviewer.
--
-- The old rule took the FIRST active agent on the project whose name matched
-- '%Architect%', falling through to a QA-pattern match only when the architect was
-- the developer. For SupaBrain that resolved to System Architect on essentially
-- every item, so the queue could not spread: 10 of 12 items in review, against a
-- max_concurrent_tasks of 3.
--
-- The old function already COMPUTED reviewer load and wrote meta.reviewer_over_wip
-- as an advisory. That advisory has been firing and being ignored. It now decides
-- the routing instead of describing it.
--
-- Load is normalised (count / limit) because reviewers have different capacities:
-- an architect at 2 of 3 is fuller than a QA agent at 3 of 5.
create or replace function public.enforce_review_assignee()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
DECLARE
  v_dev text;
  v_reviewer_id uuid; v_reviewer_name text;
  v_load int; v_limit int;
BEGIN
  IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN

    v_dev := NEW.assignee;

    -- The human executive reviews his own items; never reroute them.
    IF v_dev = 'Jason Paulsen' THEN RETURN NEW; END IF;

    -- Eligible reviewers on this project, least-loaded first. Same eligibility
    -- patterns as before (Architect / QA / Verification / Playtester); what changed
    -- is that all candidates compete on load rather than the first match winning.
    SELECT a.id, a.name INTO v_reviewer_id, v_reviewer_name
    FROM agents a
    JOIN agent_projects ap ON ap.agent_id = a.id AND ap.project_id = NEW.project_id
    WHERE a.status = 'active'
      AND a.name IS DISTINCT FROM v_dev
      AND (a.name ILIKE '%Architect%' OR a.name ILIKE '%QA%'
           OR a.name ILIKE '%Verification%' OR a.name ILIKE '%Playtester%')
    ORDER BY
      (SELECT count(*) FROM work_items w
        WHERE w.assignee = a.name AND w.status = 'review' AND NOT w.archived
          AND w.id IS DISTINCT FROM NEW.id)::numeric
        / GREATEST(COALESCE(a.max_concurrent_tasks, 5), 1) ASC,
      a.name ASC
    LIMIT 1;

    -- Backstop unchanged: the two global reviewers, when the project has none.
    IF v_reviewer_id IS NULL THEN
      SELECT a.id, a.name INTO v_reviewer_id, v_reviewer_name FROM agents a
      WHERE a.name = CASE WHEN v_dev = 'SupaBrain QA' THEN 'System Architect' ELSE 'SupaBrain QA' END
        AND a.status = 'active' LIMIT 1;
    END IF;

    IF v_reviewer_id IS NULL THEN
      RAISE EXCEPTION 'SB-327: Cannot move % to review — no reviewer resolvable for project %.',
        COALESCE(NEW.ticket_code, NEW.id::text), NEW.project_id;
    END IF;

    -- Preserve the developer (first reassignment wins; rework loops keep the original)
    IF v_dev IS NOT NULL AND v_dev <> '' AND NOT (coalesce(NEW.meta,'{}'::jsonb) ? 'developed_by') THEN
      NEW.meta := coalesce(NEW.meta,'{}'::jsonb) || jsonb_build_object('developed_by', v_dev);
    END IF;

    NEW.assigned_agent_id := v_reviewer_id;
    NEW.assignee := v_reviewer_name;

    SELECT count(*), coalesce(max(a.max_concurrent_tasks),5) INTO v_load, v_limit
    FROM work_items w, agents a
    WHERE w.assignee = v_reviewer_name AND w.status = 'review' AND NOT w.archived
      AND w.id IS DISTINCT FROM NEW.id AND a.id = v_reviewer_id;

    NEW.meta := coalesce(NEW.meta,'{}'::jsonb) || jsonb_build_object('review_routed',
      format('SB-377: routed to %s (%s/%s in review) on %s',
             v_reviewer_name, v_load, v_limit, now()::date));
  END IF;

  RETURN NEW;
END $function$;
;
