
-- SB-158: Reconcile assignee name mismatches
-- 
-- Fix 1: "Process Engineer" → "SupaBrain Process Engineer" (matches agents table)
-- Fix 2: Backfill completed_at on done tickets where missing (70 rows)
-- Note: "Jason Paulsen" is the human owner, not an agent — left intentionally as-is
-- Note: "Anonymous Agent (untracked)" is a deliberate placeholder — left as-is
-- Note: "Kelshe"/"Navigator" mismatches from ticket description are already resolved

-- Fix assignee mismatch: Process Engineer → SupaBrain Process Engineer
UPDATE work_items 
SET assignee = 'SupaBrain Process Engineer', updated_at = NOW()
WHERE assignee = 'Process Engineer';

-- Backfill completed_at on done tickets where missing
UPDATE work_items 
SET completed_at = updated_at 
WHERE status = 'done' AND completed_at IS NULL;
;
