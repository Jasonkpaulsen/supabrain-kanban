
-- SB-084: QA gate enforcement — require at least 1 test case before done
--
-- Testable types that REQUIRE test cases: task, bug, user_story
-- Exempt types: epic, chore, spike, requirement
-- Trigger: BEFORE UPDATE on work_items
-- Condition: status is changing TO 'done' on a testable type

CREATE OR REPLACE FUNCTION enforce_qa_gate()
RETURNS TRIGGER AS $$
DECLARE
  test_count int;
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
BEGIN
  -- Only fire when status is changing TO 'done'
  IF NEW.status = 'done' AND (OLD.status IS NULL OR OLD.status != 'done') THEN
    -- Skip exempt types
    IF NEW.type = ANY(exempt_types) THEN
      RETURN NEW;
    END IF;

    -- Count test cases linked to this work item
    SELECT COUNT(*) INTO test_count
    FROM test_cases
    WHERE work_item_id = NEW.id;

    IF test_count = 0 THEN
      RAISE EXCEPTION 'QA-GATE: ticket % (type=%) cannot move to done — requires at least 1 test case. Currently has 0 test cases linked. Exempt types: epic, chore, spike, requirement.',
        NEW.ticket_code, NEW.type;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create the trigger (drop first if exists for idempotency)
DROP TRIGGER IF EXISTS trg_qa_gate ON work_items;

CREATE TRIGGER trg_qa_gate
  BEFORE UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_qa_gate();

COMMENT ON FUNCTION enforce_qa_gate() IS 
  'SB-084: Definition-of-Done gate requiring at least 1 test_case before a ticket '
  'can move to status=done. Applies to types: task, bug, user_story. '
  'Exempt types: epic, chore, spike, requirement.';
;
