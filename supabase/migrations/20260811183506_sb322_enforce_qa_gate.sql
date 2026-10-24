-- SB-322: the QA gate was advisory. It set qa_status, wrote an advisory warning,
-- and let the transition through -- unlike the approval and review gates, which raise.
-- It also resolved qa_status from COUNT(*) > 0 alone, so a ticket whose tests all
-- failed was marked 'tested'. Both halves are fixed together: a raising gate on a
-- wrong signal would be no better than no gate.
--
-- Deliberate deviation from the drafted design: NO created_at grandfather. Grandfathering
-- by created_at would exempt all 263 currently-open engineering tickets, leaving the rule
-- inert for months. Already-done rows are untouched regardless, because this trigger only
-- fires on the transition INTO done. meta.qa_gate_exempt remains the escape hatch.
create or replace function public.enforce_qa_gate()
returns trigger language plpgsql set search_path to 'public' as $$
DECLARE
  test_count int;
  fail_count int;
  unrun_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  is_design boolean := false;
  project_domain text;
  engineering_domains text[] := ARRAY['products', 'operations', 'prediction-markets'];
BEGIN
  -- Moving OUT of done: clear qa_status
  IF TG_OP = 'UPDATE' AND OLD.status = 'done' AND NEW.status != 'done' THEN
    NEW.qa_status := NULL;
    RETURN NEW;
  END IF;

  -- Moving INTO done
  IF NEW.status = 'done' AND (TG_OP = 'INSERT' OR OLD.status IS NULL OR OLD.status != 'done') THEN

    SELECT p.domain INTO project_domain FROM projects p WHERE p.id = NEW.project_id;

    IF project_domain IS NULL OR NOT (project_domain = ANY(engineering_domains)) THEN
      NEW.qa_status := 'exempt'; RETURN NEW;
    END IF;

    IF NEW.type = ANY(exempt_types) THEN
      NEW.qa_status := 'exempt'; RETURN NEW;
    END IF;

    IF (NEW.meta->>'qa_gate_exempt')::boolean = true THEN
      NEW.qa_status := 'exempt'; RETURN NEW;
    END IF;

    IF NEW.title ~* '\m(design|mockup|wireframe|prototype|layout|visual)\M' OR NEW.title ~* '\mIA\M' THEN
      is_design := true;
    END IF;
    IF NOT is_design AND NEW.meta ? 'deliverable' THEN
      IF NEW.meta->>'deliverable' ~* '(mockup|design|wireframe|prototype|diagram|layout)' THEN
        is_design := true;
      END IF;
    END IF;
    IF is_design THEN
      NEW.qa_status := 'exempt'; RETURN NEW;
    END IF;

    -- Resolve from actual results, not from the mere existence of rows.
    SELECT count(*),
           count(*) FILTER (WHERE last_result = 'fail'),
           count(*) FILTER (WHERE last_result IS NULL)
      INTO test_count, fail_count, unrun_count
      FROM test_cases WHERE work_item_id = NEW.id;

    IF test_count = 0 THEN
      NEW.qa_status := 'untested';
      RAISE EXCEPTION
        'QA required: ticket % cannot move to done with no test cases. '
        'Draft and execute test cases first, or set meta.qa_gate_exempt = true to bypass this gate.',
        COALESCE(NEW.ticket_code, NEW.id::text);
    END IF;

    IF fail_count > 0 THEN
      NEW.qa_status := 'defect-found';
      RAISE EXCEPTION
        'QA failed: ticket % cannot move to done with % failing test case(s). '
        'Fix the defect and re-run, or set meta.qa_gate_exempt = true to bypass this gate.',
        COALESCE(NEW.ticket_code, NEW.id::text), fail_count;
    END IF;

    IF unrun_count > 0 THEN
      NEW.qa_status := 'untested';
      RAISE EXCEPTION
        'QA incomplete: ticket % has % test case(s) that have not been executed. '
        'Execute them, or set meta.qa_gate_exempt = true to bypass this gate.',
        COALESCE(NEW.ticket_code, NEW.id::text), unrun_count;
    END IF;

    NEW.qa_status := 'tested';
  END IF;

  RETURN NEW;
END;
$$;;
