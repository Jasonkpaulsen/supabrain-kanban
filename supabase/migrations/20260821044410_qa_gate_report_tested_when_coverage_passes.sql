CREATE OR REPLACE FUNCTION public.enforce_qa_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  test_count int;
  fail_count int;
  unrun_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  is_design boolean := false;
  is_exempt boolean := false;
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

    -- Measure coverage FIRST. Previously each exemption branch returned before
    -- reaching this, so a ticket with full passing coverage still reported
    -- 'exempt' whenever it happened to be a chore, a design item, or to sit in
    -- a non-engineering project. That understated verification: 'exempt' reads
    -- as "not verified" to anyone auditing, and two independent paths could
    -- produce it for tickets that were in fact tested.
    SELECT count(*),
           count(*) FILTER (WHERE last_result = 'fail'),
           count(*) FILTER (WHERE last_result IS NULL)
      INTO test_count, fail_count, unrun_count
      FROM test_cases WHERE work_item_id = NEW.id;

    SELECT p.domain INTO project_domain FROM projects p WHERE p.id = NEW.project_id;

    -- Exemption reasons, evaluated but no longer short-circuiting.
    IF project_domain IS NULL OR NOT (project_domain = ANY(engineering_domains)) THEN
      is_exempt := true;
    END IF;

    IF NEW.type = ANY(exempt_types) THEN
      is_exempt := true;
    END IF;

    IF (NEW.meta->>'qa_gate_exempt')::boolean = true THEN
      is_exempt := true;
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
      is_exempt := true;
    END IF;

    -- An exempt ticket is never BLOCKED. But if it carries coverage and that
    -- coverage passes, say so rather than hiding it behind 'exempt'.
    IF is_exempt THEN
      IF test_count > 0 AND fail_count = 0 AND unrun_count = 0 THEN
        NEW.qa_status := 'tested';
      ELSE
        NEW.qa_status := 'exempt';
      END IF;
      RETURN NEW;
    END IF;

    -- Not exempt: the gate applies in full. Every RAISE below is unchanged.
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
$function$;;
