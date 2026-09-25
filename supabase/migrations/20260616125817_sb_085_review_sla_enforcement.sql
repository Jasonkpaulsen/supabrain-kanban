
-- SB-085: Review SLA enforcement — 24h review queue tracking
--
-- 1. Add review_entered_at timestamp column
-- 2. Create trigger to set review_entered_at when status → 'review'
-- 3. Create vw_review_sla view showing tickets in review with SLA status
-- 4. Create escalation function for overdue reviews
-- 5. Backfill review_entered_at for items currently in review

-- Step 1: Add column (idempotent via IF NOT EXISTS)
ALTER TABLE work_items 
ADD COLUMN IF NOT EXISTS review_entered_at timestamptz;

COMMENT ON COLUMN work_items.review_entered_at IS 
  'SB-085: Timestamp when ticket entered review status. Set by trg_review_sla_tracker trigger. Used for 24h SLA tracking.';

-- Step 2: Create trigger function to track review entry
CREATE OR REPLACE FUNCTION track_review_entry()
RETURNS TRIGGER AS $$
BEGIN
  -- When status changes TO 'review', record the timestamp
  IF NEW.status = 'review' AND (OLD.status IS NULL OR OLD.status != 'review') THEN
    NEW.review_entered_at := NOW();
  END IF;
  
  -- When status changes AWAY FROM 'review', clear the timestamp
  IF NEW.status != 'review' AND OLD.status = 'review' THEN
    NEW.review_entered_at := NULL;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_review_sla_tracker ON work_items;

CREATE TRIGGER trg_review_sla_tracker
  BEFORE UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION track_review_entry();

COMMENT ON FUNCTION track_review_entry() IS 
  'SB-085: Sets review_entered_at when ticket enters review, clears it when leaving review.';

-- Step 3: Create SLA view
CREATE OR REPLACE VIEW vw_review_sla AS
SELECT 
  w.id,
  w.ticket_code,
  w.title,
  w.type,
  w.priority,
  w.assignee,
  w.review_entered_at,
  w.project_id,
  EXTRACT(EPOCH FROM (NOW() - w.review_entered_at)) / 3600.0 AS hours_in_review,
  CASE 
    WHEN EXTRACT(EPOCH FROM (NOW() - w.review_entered_at)) / 3600.0 > 24 THEN true
    ELSE false
  END AS sla_breached,
  CASE 
    WHEN EXTRACT(EPOCH FROM (NOW() - w.review_entered_at)) / 3600.0 > 48 THEN 'CRITICAL'
    WHEN EXTRACT(EPOCH FROM (NOW() - w.review_entered_at)) / 3600.0 > 24 THEN 'BREACHED'
    WHEN EXTRACT(EPOCH FROM (NOW() - w.review_entered_at)) / 3600.0 > 20 THEN 'AT_RISK'
    ELSE 'OK'
  END AS sla_status,
  w.authority_level,
  p.name AS project_name
FROM work_items w
JOIN projects p ON p.id = w.project_id
WHERE w.status = 'review';

COMMENT ON VIEW vw_review_sla IS 
  'SB-085: Shows tickets currently in review with 24h SLA tracking. '
  'sla_status: OK (<20h), AT_RISK (20-24h), BREACHED (24-48h), CRITICAL (>48h).';

-- Step 4: Create escalation function
CREATE OR REPLACE FUNCTION escalate_overdue_reviews(p_user_id uuid DEFAULT NULL)
RETURNS TABLE (
  ticket_code text,
  title text,
  hours_in_review double precision,
  sla_status text,
  assignee text,
  project_name text
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    v.ticket_code,
    v.title,
    v.hours_in_review,
    v.sla_status,
    v.assignee,
    v.project_name
  FROM vw_review_sla v
  JOIN work_items w ON w.id = v.id
  WHERE v.sla_breached = true
    AND (p_user_id IS NULL OR w.user_id = p_user_id)
  ORDER BY v.hours_in_review DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION escalate_overdue_reviews(uuid) IS 
  'SB-085: Returns all review-queue tickets that have breached the 24h SLA. '
  'Call with user_id to scope to a specific user, or NULL for all.';

-- Step 5: Backfill review_entered_at for items currently in review
-- Use updated_at as best estimate for when they entered review
UPDATE work_items 
SET review_entered_at = updated_at
WHERE status = 'review' AND review_entered_at IS NULL;
;
