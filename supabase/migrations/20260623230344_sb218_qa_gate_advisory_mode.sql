
ALTER TABLE work_items ADD COLUMN IF NOT EXISTS qa_status text;

COMMENT ON COLUMN work_items.qa_status IS 'QA classification set by advisory gate on status->done. Values: tested, untested, exempt. NULL for non-done tickets.';

CREATE OR REPLACE FUNCTION enforce_qa_gate()
RETURNS TRIGGER AS $$
DECLARE
  test_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  is_design boolean := false;
BEGIN
  IF OLD.status = 'done' AND NEW.status != 'done' THEN
    NEW.qa_status := NULL;
    RETURN NEW;
  END IF;

  IF NEW.status = 'done' AND (OLD.status IS NULL OR OLD.status != 'done') THEN
    IF NEW.type = ANY(exempt_types) THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

    IF (NEW.meta->>'qa_gate_exempt')::boolean = true THEN
      NEW.qa_status := 'exempt';
      RETURN NEW;
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
      NEW.qa_status := 'exempt';
      RETURN NEW;
    END IF;

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

CREATE OR REPLACE VIEW v_qa_coverage AS
SELECT p.name AS project_name, p.id AS project_id, wi.type,
  COUNT(*) AS total_done,
  COUNT(*) FILTER (WHERE wi.qa_status = 'tested') AS tested,
  COUNT(*) FILTER (WHERE wi.qa_status = 'untested') AS untested,
  COUNT(*) FILTER (WHERE wi.qa_status = 'exempt') AS exempt,
  COUNT(*) FILTER (WHERE wi.qa_status IS NULL) AS unclassified,
  ROUND(CASE WHEN COUNT(*) FILTER (WHERE wi.qa_status IN ('tested','untested')) > 0 THEN COUNT(*) FILTER (WHERE wi.qa_status = 'tested')::numeric / COUNT(*) FILTER (WHERE wi.qa_status IN ('tested','untested'))::numeric * 100 ELSE 0 END, 1) AS coverage_pct
FROM work_items wi JOIN projects p ON p.id = wi.project_id
WHERE wi.status = 'done'
GROUP BY p.id, p.name, wi.type
ORDER BY p.name, wi.type;

UPDATE work_items SET qa_status = 'exempt' WHERE status = 'done' AND type IN ('epic', 'chore', 'spike', 'requirement') AND qa_status IS NULL;

UPDATE work_items SET qa_status = 'exempt' WHERE status = 'done' AND (meta->>'qa_gate_exempt')::boolean = true AND qa_status IS NULL;

UPDATE work_items SET qa_status = 'exempt' WHERE status = 'done' AND qa_status IS NULL AND (title ~* '\m(design|mockup|wireframe|prototype|layout|visual)\M' OR title ~* '\mIA\M' OR (meta ? 'deliverable' AND meta->>'deliverable' ~* '(mockup|design|wireframe|prototype|diagram|layout)'));

UPDATE work_items SET qa_status = 'tested' WHERE status = 'done' AND qa_status IS NULL AND id IN (SELECT work_item_id FROM test_cases);

UPDATE work_items SET qa_status = 'untested' WHERE status = 'done' AND qa_status IS NULL AND type IN ('task', 'bug', 'user_story');
;
