
-- Fix: QA gate trigger was too aggressive — blocking ALL tickets without test cases,
-- including pre-existing work that was never designed with the QA gate in mind.
--
-- Changes:
-- 1. Add meta->>'qa_gate_exempt' = 'true' bypass flag for per-ticket exemptions
-- 2. Grandfather all tickets created before 2026-06-17 (gate effective date)
-- 3. Improved error message mentioning the bypass mechanism
--
-- Reference: SB-084

CREATE OR REPLACE FUNCTION enforce_qa_gate()
RETURNS TRIGGER AS $$
DECLARE
  test_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  -- Only enforce on tickets created on or after this date
  gate_effective_date timestamptz := '2026-06-17T00:00:00Z';
BEGIN
  -- Only fire when status is changing TO 'done'
  IF NEW.status = 'done' AND (OLD.status IS NULL OR OLD.status != 'done') THEN
    -- Skip exempt types
    IF NEW.type = ANY(exempt_types) THEN
      RETURN NEW;
    END IF;

    -- Skip if explicitly exempted via meta flag
    IF (NEW.meta->>'qa_gate_exempt')::boolean = true THEN
      RETURN NEW;
    END IF;

    -- Grandfather tickets created before the gate was deployed
    IF NEW.created_at < gate_effective_date THEN
      RETURN NEW;
    END IF;

    -- Count test cases linked to this work item
    SELECT COUNT(*) INTO test_count
    FROM test_cases
    WHERE work_item_id = NEW.id;

    IF test_count = 0 THEN
      RAISE EXCEPTION 'QA-GATE: ticket % (type=%) cannot move to done — requires at least 1 test case (0 found). To bypass: UPDATE work_items SET meta = jsonb_set(coalesce(meta,''{}''), ''{qa_gate_exempt}'', ''true'') WHERE ticket_code = ''%''. Exempt types: epic, chore, spike, requirement.',
        NEW.ticket_code, NEW.type, NEW.ticket_code;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
;
