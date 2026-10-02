
-- SB-086: Enforce approval gate before work_items enter active states
-- Prevents transition to in_progress or review unless approval_status = 'approved'

CREATE OR REPLACE FUNCTION enforce_approval_gate()
RETURNS TRIGGER AS $$
BEGIN
  -- Only fire when status is changing TO an active state
  IF NEW.status IN ('in_progress', 'review') 
     AND (OLD.status IS NULL OR OLD.status NOT IN ('in_progress', 'review') OR OLD.status != NEW.status)
     AND NEW.approval_status != 'approved'
  THEN
    RAISE EXCEPTION 'Approval required: ticket % cannot move to % without approval_status = approved (current: %)',
      NEW.ticket_code, NEW.status, NEW.approval_status;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop if exists to make idempotent
DROP TRIGGER IF EXISTS trg_approval_gate ON work_items;

CREATE TRIGGER trg_approval_gate
  BEFORE UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_approval_gate();

COMMENT ON FUNCTION enforce_approval_gate() IS 'SB-086: Prevents work_items from entering in_progress or review without approval_status = approved';
;
