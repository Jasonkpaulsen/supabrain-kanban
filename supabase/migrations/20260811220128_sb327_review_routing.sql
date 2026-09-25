-- SB-327: SB-286 only assigned a reviewer when assignee was EMPTY, so tickets kept
-- their developer through review and nobody was accountable for reviewing. Now entry
-- to review ALWAYS routes to a reviewer who is not the developer, preserving the
-- developer in meta.developed_by. Jason's own items are exempt (ADR-IDENT-001).
create or replace function public.enforce_review_assignee()
returns trigger language plpgsql set search_path to 'public' as $$
DECLARE
  v_dev text;
  v_architect_id uuid; v_architect_name text;
  v_qa_id uuid; v_qa_name text;
  v_reviewer_id uuid; v_reviewer_name text;
  v_load int; v_limit int;
BEGIN
  IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN

    v_dev := NEW.assignee;

    -- The human executive reviews his own items; never reroute them.
    IF v_dev = 'Jason Paulsen' THEN RETURN NEW; END IF;

    -- Candidate 1: the project's Architect (SB-286 lookup, unchanged)
    SELECT a.id, a.name INTO v_architect_id, v_architect_name
    FROM agents a JOIN agent_projects ap ON ap.agent_id=a.id AND ap.project_id=NEW.project_id
    WHERE a.name ILIKE '%Architect%' AND a.status='active' LIMIT 1;

    -- Candidate 2: the project's QA agent (QA Routing & Testing Standard, SB-330)
    SELECT a.id, a.name INTO v_qa_id, v_qa_name
    FROM agents a JOIN agent_projects ap ON ap.agent_id=a.id AND ap.project_id=NEW.project_id
    WHERE (a.name ILIKE '%QA%' OR a.name ILIKE '%Verification%' OR a.name ILIKE '%Playtester%')
      AND a.status='active' LIMIT 1;

    -- Pick the first candidate who is not the developer; SupaBrain QA, then System
    -- Architect, backstop the case where the developer IS the project reviewer.
    IF v_architect_name IS NOT NULL AND v_architect_name IS DISTINCT FROM v_dev THEN
      v_reviewer_id := v_architect_id; v_reviewer_name := v_architect_name;
    ELSIF v_qa_name IS NOT NULL AND v_qa_name IS DISTINCT FROM v_dev THEN
      v_reviewer_id := v_qa_id; v_reviewer_name := v_qa_name;
    ELSE
      SELECT a.id, a.name INTO v_reviewer_id, v_reviewer_name FROM agents a
      WHERE a.name = CASE WHEN v_dev='SupaBrain QA' THEN 'System Architect' ELSE 'SupaBrain QA' END
        AND a.status='active' LIMIT 1;
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

    -- Reviewer load flag: advisory, never a block. Review has no WIP redirect, so an
    -- overloaded reviewer is surfaced to the briefing instead of silently queueing.
    SELECT count(*), coalesce(max(a.max_concurrent_tasks),5) INTO v_load, v_limit
    FROM work_items w, agents a
    WHERE w.assignee=v_reviewer_name AND w.status='review' AND NOT w.archived
      AND w.id IS DISTINCT FROM NEW.id AND a.id=v_reviewer_id;
    IF v_load >= v_limit THEN
      NEW.meta := coalesce(NEW.meta,'{}'::jsonb) || jsonb_build_object('reviewer_over_wip',
        format('%s has %s items already in review (limit %s)', v_reviewer_name, v_load, v_limit));
    END IF;

    NEW.meta := coalesce(NEW.meta,'{}'::jsonb) || jsonb_build_object('review_routed',
      format('SB-327: routed to %s on %s', v_reviewer_name, now()::date));
  END IF;

  RETURN NEW;
END $$;

-- Daily surfacing of the SLA view nobody was reading (48h soft / 72h hard breaches)
create or replace function public.review_sla_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_breaches jsonb; v_over jsonb; v_summary text;
begin
  select coalesce(jsonb_agg(jsonb_build_object('ticket',ticket_code,'reviewer',assignee,
           'hours',hours_in_review,'level',breach_level) order by hours_in_review desc),'[]'::jsonb)
    into v_breaches from v_review_sla_breaches;

  select coalesce(jsonb_agg(jsonb_build_object('ticket',ticket_code,'note',meta->>'reviewer_over_wip')),'[]'::jsonb)
    into v_over from work_items
  where status='review' and not archived and meta ? 'reviewer_over_wip';

  v_summary := case
    when jsonb_array_length(v_breaches)=0 and jsonb_array_length(v_over)=0
      then 'Review SLA: all clear — no breach over 48h, no overloaded reviewer.'
    else format('Review SLA: %s breach(es) (48h+), %s overloaded-reviewer flag(s).',
                jsonb_array_length(v_breaches), jsonb_array_length(v_over))
  end;

  insert into activity_log (project_id,user_id,agent_name,action,target_table,summary,meta)
  values ('a07a7f3d-722f-468f-81fa-84e2c5fba704','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
          'System','commented','work_items', v_summary,
          jsonb_build_object('artifact','review_sla','breaches',v_breaches,'overloaded',v_over));

  return jsonb_build_object('summary',v_summary,'breaches',v_breaches,'overloaded',v_over);
end $$;

revoke execute on function public.review_sla_sweep() from anon, authenticated, public;

select cron.schedule('review-sla-daily', '0 8 * * *', $$select public.review_sla_sweep()$$);;
