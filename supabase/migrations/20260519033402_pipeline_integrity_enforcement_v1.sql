-- ============================================================================
-- LAYER 1: read-only audit view — every integrity violation visible at a glance
-- ============================================================================
CREATE OR REPLACE VIEW vw_pipeline_integrity_violations AS
WITH gen AS (
  SELECT job_application_id, COUNT(*) AS gen_count
  FROM resume_generations
  WHERE job_application_id IS NOT NULL
  GROUP BY job_application_id
)
SELECT
  ja.id,
  ja.company,
  ja.title,
  ja.status,
  ja.decision,
  ja.applied_at,
  ja.resume_file,
  COALESCE(g.gen_count, 0) AS resume_generations_count,
  ARRAY_REMOVE(ARRAY[
    CASE WHEN ja.status = 'applied' AND COALESCE(g.gen_count,0) = 0
         THEN 'R1: status=applied without resume_generations row' END,
    CASE WHEN ja.status = 'applied' AND ja.resume_file IS NULL
         THEN 'R2a: status=applied without resume_file logged' END,
    CASE WHEN ja.status = 'applied' AND ja.applied_at IS NULL
         THEN 'R2b: status=applied without applied_at timestamp' END,
    CASE WHEN ja.status = 'applied'
              AND ja.resume_file IS NOT NULL
              AND ja.resume_file NOT ILIKE '%General%'
              AND ja.resume_file NOT ILIKE '%CIO_General%'
              AND ja.resume_file NOT ILIKE '%VP_PMO%'
              AND ja.resume_file !~* (
                '_' || REGEXP_REPLACE(
                  SPLIT_PART(SPLIT_PART(ja.company, ' (', 1), '/', 1),
                  '[^A-Za-z0-9]', '', 'g'
                ) || '_'
              )
         THEN 'R3: resume_file appears unrelated to target company (verify)' END,
    CASE WHEN ja.decision = 'apply' AND ja.status = 'new'
              AND ja.score IS NOT NULL AND ja.score < 3.0
         THEN 'R4: decision=apply with score < 3.0 — below v3 threshold' END,
    CASE WHEN ja.decision = 'skip' AND ja.status NOT IN ('skipped','rejected','withdrawn')
         THEN 'R5: decision=skip but status not in (skipped/rejected/withdrawn)' END,
    CASE WHEN ja.decision IN ('MODERATE_MATCH','WEAK_MATCH','STRONG_MATCH','applied')
         THEN 'R6: legacy decision label still present (v3 migration miss)' END
  ], NULL) AS violations
FROM job_applications ja
LEFT JOIN gen g ON g.job_application_id = ja.id;

-- ============================================================================
-- LAYER 2: pre-apply check function — call before flipping to status='applied'
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_pre_apply_check(p_job_app_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_row job_applications%ROWTYPE;
  v_gen_count int;
  v_violations text[] := ARRAY[]::text[];
  v_company_token text;
BEGIN
  SELECT * INTO v_row FROM job_applications WHERE id = p_job_app_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'job_application not found', 'id', p_job_app_id);
  END IF;

  SELECT COUNT(*) INTO v_gen_count FROM resume_generations WHERE job_application_id = p_job_app_id;

  -- R1: resume_generations row required
  IF v_gen_count = 0 THEN
    v_violations := array_append(v_violations, 'R1: no resume_generations row — Stage 3 must run before applying');
  END IF;

  -- R2a: resume_file logged
  IF v_row.resume_file IS NULL THEN
    v_violations := array_append(v_violations, 'R2a: resume_file is NULL — log the file name being submitted');
  ELSE
    -- R3: resume_file matches target or is a documented general base
    v_company_token := REGEXP_REPLACE(SPLIT_PART(SPLIT_PART(v_row.company, ' (', 1), '/', 1), '[^A-Za-z0-9]', '', 'g');
    IF v_row.resume_file !~* '(General|CIO_General|VP_PMO)'
       AND v_row.resume_file !~* ('_' || v_company_token || '_')
    THEN
      v_violations := array_append(v_violations,
        'R3: resume_file (' || v_row.resume_file || ') does not match target company (' || v_company_token ||
        ') and is not a documented general base — possible wrong-target file');
    END IF;
  END IF;

  -- R4: score sanity
  IF v_row.score IS NOT NULL AND v_row.score < 3.0 THEN
    v_violations := array_append(v_violations, 'R4: score ' || v_row.score::text || ' is below v3 apply threshold (3.0)');
  END IF;

  -- R5/R6: legacy labels
  IF v_row.decision IN ('MODERATE_MATCH','WEAK_MATCH','STRONG_MATCH','applied') THEN
    v_violations := array_append(v_violations, 'R6: legacy decision label "' || v_row.decision || '" — migrate to apply/review/skip first');
  END IF;

  RETURN jsonb_build_object(
    'ok', cardinality(v_violations) = 0,
    'job_application_id', p_job_app_id,
    'company', v_row.company,
    'title', v_row.title,
    'violations', to_jsonb(v_violations),
    'checked_at', NOW()
  );
END;
$$;

-- ============================================================================
-- LAYER 3: BEFORE UPDATE trigger — block status→applied if integrity fails,
-- with manual override via notes field containing '[override-apply-guard]'.
-- ============================================================================
CREATE OR REPLACE FUNCTION fn_apply_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_check jsonb;
  v_violations jsonb;
BEGIN
  -- only fire when status is transitioning into 'applied'
  IF NEW.status = 'applied' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    -- explicit user-acknowledged override
    IF COALESCE(NEW.notes,'') ILIKE '%[override-apply-guard]%' THEN
      RAISE NOTICE 'apply-guard bypassed for job_application % via override token in notes', NEW.id;
      RETURN NEW;
    END IF;
    v_check := fn_pre_apply_check(NEW.id);
    IF (v_check->>'ok')::boolean = false THEN
      v_violations := v_check->'violations';
      RAISE EXCEPTION 'Apply-guard blocked status→applied for %: violations = %. To override, append "[override-apply-guard]" to notes and retry.',
        NEW.id, v_violations;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_apply_guard ON job_applications;
CREATE TRIGGER tg_apply_guard
  BEFORE UPDATE ON job_applications
  FOR EACH ROW
  EXECUTE FUNCTION fn_apply_guard();

COMMENT ON VIEW vw_pipeline_integrity_violations IS
  'Read-only audit of pipeline integrity per v3 rules locked 2026-05-18. Each row lists any active rule violations.';
COMMENT ON FUNCTION fn_pre_apply_check(uuid) IS
  'Returns {ok: bool, violations: []} for a given job_application. Call before flipping status to applied.';
COMMENT ON FUNCTION fn_apply_guard() IS
  'Trigger function — blocks status→applied transitions that fail fn_pre_apply_check. Override with [override-apply-guard] token in notes.';
COMMENT ON TRIGGER tg_apply_guard ON job_applications IS
  'Apply-guard trigger (v1 — installed 2026-05-18 after Zurich post-mortem).';;
