
-- SB-253: Scope QA gate by project domain
-- Engineering domains: products, operations, prediction-markets
-- Non-engineering domains auto-exempt from QA requirements

CREATE OR REPLACE FUNCTION enforce_qa_gate()
RETURNS TRIGGER AS $$
DECLARE
  test_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  is_design boolean := false;
  project_domain text;
  engineering_domains text[] := ARRAY['products', 'operations', 'prediction-markets'];
BEGIN
  -- Moving OUT of done: clear qa_status
  IF OLD.status = 'done' AND NEW.status != 'done' THEN
    NEW.qa_status := NULL;
    RETURN NEW;
  END IF;

  -- Moving INTO done
  IF NEW.status = 'done' AND (OLD.status IS NULL OR OLD.status != 'done') THEN

    -- Domain scoping: exempt non-engineering projects
    SELECT p.domain INTO project_domain
    FROM projects p WHERE p.id = NEW.project_id;

    IF project_domain IS NULL OR NOT (project_domain = ANY(engineering_domains)) THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

    -- Type exemptions (existing)
    IF NEW.type = ANY(exempt_types) THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

    -- Manual exemption via meta flag (existing)
    IF (NEW.meta->>'qa_gate_exempt')::boolean = true THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

    -- Design ticket detection (existing)
    IF NEW.title ~* '\m(design|mockup|wireframe|prototype|layout|visual)\M' OR NEW.title ~* '\mIA\M' THEN
      is_design := true;
    END IF;

    IF NOT is_design AND NEW.meta ? 'deliverable' THEN
      IF NEW.meta->>'deliverable' ~* '(mockup|design|wireframe|prototype|diagram|layout)' THEN
        is_design := true;
      END IF;
    END IF;

    IF is_design THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

    -- Check for test cases
    SELECT COUNT(*) INTO test_count FROM test_cases WHERE work_item_id = NEW.id;

    IF test_count > 0 THEN
      NEW.qa_status := 'tested';
    ELSE
      NEW.qa_status := 'untested';
      NEW.meta := jsonb_set(coalesce(NEW.meta, '{}'), '{qa_advisory_warning}', to_jsonb(format('Moved to done without test cases — flagged by QA advisory gate on %s', now()::date::text)));
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
;
