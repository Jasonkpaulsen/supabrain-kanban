
-- ============================================================================
-- SB-234: Enforce review/QA + approval gates on transition to done
-- Three coordinated changes to close path-to-done leaks.
-- See ADR-FLOW-002 / SB-229 for design context.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ADD review_completed_at COLUMN
-- ---------------------------------------------------------------------------
ALTER TABLE work_items
  ADD COLUMN IF NOT EXISTS review_completed_at timestamptz;

COMMENT ON COLUMN work_items.review_completed_at IS
  'Timestamp when review was completed (review->done transition). Set by track_review_entry trigger. SB-234.';

-- ---------------------------------------------------------------------------
-- 2. REPLACE track_review_entry() — preserve review_entered_at on done
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION track_review_entry()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- When status changes TO 'review', record the entry timestamp
  IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN
    NEW.review_entered_at := NOW();
    NEW.review_completed_at := NULL;  -- reset completed since we are (re-)entering review
  END IF;

  -- When status changes FROM 'review' TO 'done':
  --   PRESERVE review_entered_at (evidence the card passed through review)
  --   SET review_completed_at
  IF OLD.status = 'review' AND NEW.status = 'done' THEN
    -- review_entered_at intentionally NOT cleared
    NEW.review_completed_at := NOW();
  END IF;

  -- When status changes FROM 'review' to a PRE-REVIEW state: clear timestamps
  IF OLD.status = 'review' AND NEW.status IN ('todo', 'in_progress', 'backlog') THEN
    NEW.review_entered_at := NULL;
    NEW.review_completed_at := NULL;
  END IF;

  -- When status changes OUT OF 'done': clear review_completed_at
  -- (review_entered_at is preserved so re-entry to review is tracked)
  IF OLD.status = 'done' AND NEW.status != 'done' THEN
    NEW.review_completed_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. CREATE enforce_done_gate() — blocking gates on transition to done
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enforce_done_gate()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  exempt_types text[] := ARRAY['epic', 'chore', 'spike', 'requirement'];
  grandfather_date timestamptz := '2026-06-17T00:00:00Z';
BEGIN
  -- Only fire on transition INTO done
  IF NEW.status != 'done' OR (OLD.status IS NOT NULL AND OLD.status = 'done') THEN
    RETURN NEW;
  END IF;

  -- =========================================================================
  -- GATE 1: APPROVAL GATE
  -- Block tickets with approval_status = 'pending' from reaching done.
  -- Allows: 'approved', 'not_required'
  -- Exemptions: grandfathered (created before 2026-06-17), meta.approval_gate_exempt
  -- =========================================================================
  IF NEW.approval_status = 'pending'
     AND NEW.created_at >= grandfather_date
     AND NOT COALESCE((NEW.meta->>'approval_gate_exempt')::boolean, false)
  THEN
    RAISE EXCEPTION
      'Approval required: ticket % cannot move to done with approval_status = ''pending'' (current: %). '
      'Get approval first (set approval_status to ''approved'' or ''not_required''), '
      'or set meta.approval_gate_exempt = true to bypass this gate.',
      NEW.ticket_code, NEW.approval_status;
  END IF;

  -- =========================================================================
  -- GATE 2: REVIEW-REQUIRED GATE
  -- Non-exempt tickets created on or after 2026-06-17 must have passed
  -- through review (review_entered_at IS NOT NULL) before reaching done.
  -- Exempt types: epic, chore, spike, requirement
  -- Override: meta.review_gate_exempt = true
  -- =========================================================================
  IF NOT (NEW.type = ANY(exempt_types))
     AND NEW.created_at >= grandfather_date
     AND NOT COALESCE((NEW.meta->>'review_gate_exempt')::boolean, false)
  THEN
    -- At this trigger's firing point (trg_done_gate), track_review_entry
    -- (trg_review_sla_tracker) has NOT yet run, so NEW.review_entered_at
    -- still carries the pre-update value. For review->done transitions,
    -- OLD.status = 'review' acts as a safety fallback.
    IF NEW.review_entered_at IS NULL AND (OLD.status IS NULL OR OLD.status != 'review') THEN
      RAISE EXCEPTION
        'Review required: ticket % (type: %) cannot move to done without passing through review. '
        'review_entered_at is null — this ticket has not been reviewed. '
        'Move to review status first, or set meta.review_gate_exempt = true to bypass this gate.',
        NEW.ticket_code, NEW.type;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. CREATE TRIGGER for enforce_done_gate
-- Named trg_done_gate so it fires alphabetically after trg_approval_gate
-- but before trg_qa_gate and trg_review_sla_tracker.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_done_gate ON work_items;

CREATE TRIGGER trg_done_gate
  BEFORE UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_done_gate();

-- ---------------------------------------------------------------------------
-- ROLLBACK SCRIPT (save separately — execute to revert this migration)
-- ---------------------------------------------------------------------------
-- DROP TRIGGER IF EXISTS trg_done_gate ON work_items;
-- DROP FUNCTION IF EXISTS enforce_done_gate();
--
-- CREATE OR REPLACE FUNCTION track_review_entry()
-- RETURNS trigger
-- LANGUAGE plpgsql
-- AS $$
-- BEGIN
--   IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN
--     NEW.review_entered_at := NOW();
--   END IF;
--   IF NEW.status != 'review' AND OLD.status = 'review' THEN
--     NEW.review_entered_at := NULL;
--   END IF;
--   RETURN NEW;
-- END;
-- $$;
--
-- ALTER TABLE work_items DROP COLUMN IF EXISTS review_completed_at;
;
