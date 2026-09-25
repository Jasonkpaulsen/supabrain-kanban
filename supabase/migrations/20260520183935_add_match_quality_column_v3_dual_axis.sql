-- Add the match_quality column for the objective-scoring axis (separate from action/decision)
ALTER TABLE job_applications
ADD COLUMN IF NOT EXISTS match_quality text;

COMMENT ON COLUMN job_applications.match_quality IS
'Objective match quality from scoring rubric: STRONG_MATCH (>=4.0), MODERATE_MATCH (3.0-3.99), WEAK_MATCH (<3.0). Separate from decision (which captures action). Locked 2026-05-20.';

-- Backfill match_quality from existing score for all 244 rows
UPDATE job_applications
SET match_quality = CASE
  WHEN score IS NULL THEN NULL
  WHEN score >= 4.0 THEN 'STRONG_MATCH'
  WHEN score >= 3.0 THEN 'MODERATE_MATCH'
  ELSE 'WEAK_MATCH'
END
WHERE match_quality IS NULL;

-- Check constraint
ALTER TABLE job_applications
DROP CONSTRAINT IF EXISTS job_applications_match_quality_check;
ALTER TABLE job_applications
ADD CONSTRAINT job_applications_match_quality_check
CHECK (match_quality IS NULL OR match_quality IN ('STRONG_MATCH','MODERATE_MATCH','WEAK_MATCH'));;
