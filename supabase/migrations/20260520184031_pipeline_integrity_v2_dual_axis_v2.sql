-- View migration needs DROP first (column ordering changed)
DROP VIEW IF EXISTS vw_pipeline_integrity_violations;

CREATE VIEW vw_pipeline_integrity_violations AS
WITH gen AS (
  SELECT job_application_id, COUNT(*) AS gen_count
  FROM resume_generations
  WHERE job_application_id IS NOT NULL
  GROUP BY job_application_id
)
SELECT
  ja.id, ja.company, ja.title, ja.status, ja.decision, ja.match_quality,
  ja.applied_at, ja.resume_file,
  COALESCE(g.gen_count, 0) AS resume_generations_count,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN ja.status = 'applied' AND COALESCE(g.gen_count,0) = 0
         THEN 'R1: status=applied without resume_generations row' END,
    CASE WHEN ja.status = 'applied' AND ja.resume_file IS NULL
         THEN 'R2a: status=applied without resume_file logged' END,
    CASE WHEN ja.status = 'applied' AND ja.applied_at IS NULL
         THEN 'R2b: status=applied without applied_at timestamp' END,
    CASE WHEN ja.status = 'applied' AND ja.resume_file IS NOT NULL
              AND NOT fn_company_resume_match(ja.resume_file, ja.company)
         THEN 'R3: resume_file (' || ja.resume_file || ') does not match target (' || ja.company || ')' END,
    CASE WHEN ja.decision = 'apply' AND ja.status = 'new'
              AND ja.score IS NOT NULL AND ja.score < 3.0
         THEN 'R4: decision=apply with score < 3.0 — below v3 threshold' END,
    CASE WHEN ja.decision = 'skip' AND ja.status NOT IN ('skipped','rejected','withdrawn')
         THEN 'R5: decision=skip but status not in (skipped/rejected/withdrawn)' END,
    CASE WHEN ja.decision IN ('MODERATE_MATCH','WEAK_MATCH','STRONG_MATCH','applied')
         THEN 'R6: legacy match label in decision column (belongs in match_quality; decision should be apply/review/skip)' END,
    CASE WHEN ja.score IS NOT NULL AND ja.match_quality IS NOT NULL AND (
           (ja.score >= 4.0 AND ja.match_quality != 'STRONG_MATCH')
        OR (ja.score >= 3.0 AND ja.score < 4.0 AND ja.match_quality != 'MODERATE_MATCH')
        OR (ja.score < 3.0 AND ja.match_quality != 'WEAK_MATCH')
         ) THEN 'R7: match_quality (' || ja.match_quality || ') does not match score band (' || ja.score::text || ')' END
  ], NULL) AS violations
FROM job_applications ja
LEFT JOIN gen g ON g.job_application_id = ja.id;

-- Update fn_pre_apply_check: R6 only flags legacy in decision, not match_quality
CREATE OR REPLACE FUNCTION fn_pre_apply_check(p_job_app_id uuid)
RETURNS jsonb LANGUAGE plpgsql
AS $$
DECLARE
  v_row job_applications%ROWTYPE;
  v_gen_count int;
  v_violations text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_row FROM job_applications WHERE id = p_job_app_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'job_application not found', 'id', p_job_app_id);
  END IF;
  SELECT COUNT(*) INTO v_gen_count FROM resume_generations WHERE job_application_id = p_job_app_id;
  IF v_gen_count = 0 THEN
    v_violations := array_append(v_violations, 'R1: no resume_generations row — Stage 3 must run before applying');
  END IF;
  IF v_row.resume_file IS NULL THEN
    v_violations := array_append(v_violations, 'R2a: resume_file is NULL — log the file name being submitted');
  ELSIF NOT fn_company_resume_match(v_row.resume_file, v_row.company) THEN
    v_violations := array_append(v_violations,
      'R3: resume_file (' || v_row.resume_file || ') does not match target (' || v_row.company || ')');
  END IF;
  IF v_row.score IS NOT NULL AND v_row.score < 3.0 THEN
    v_violations := array_append(v_violations, 'R4: score ' || v_row.score::text || ' below v3 apply threshold (3.0)');
  END IF;
  IF v_row.decision IN ('MODERATE_MATCH','WEAK_MATCH','STRONG_MATCH','applied') THEN
    v_violations := array_append(v_violations,
      'R6: legacy label "' || v_row.decision || '" found in decision column (belongs in match_quality; decision should be apply/review/skip)');
  END IF;
  RETURN jsonb_build_object(
    'ok', cardinality(v_violations) = 0,
    'job_application_id', p_job_app_id,
    'company', v_row.company,
    'title', v_row.title,
    'match_quality', v_row.match_quality,
    'decision', v_row.decision,
    'violations', to_jsonb(v_violations),
    'checked_at', NOW()
  );
END;
$$;;
