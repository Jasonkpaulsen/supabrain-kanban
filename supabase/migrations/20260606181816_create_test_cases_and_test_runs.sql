-- TEST CASES: reusable test definitions
CREATE TABLE test_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  work_item_id UUID REFERENCES work_items(id) ON DELETE SET NULL,
  test_code TEXT UNIQUE,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('schema', 'rls_security', 'functional', 'regression', 'integration', 'performance', 'ui_visual', 'accessibility', 'data_integrity')),
  test_type TEXT NOT NULL DEFAULT 'manual' CHECK (test_type IN ('manual', 'sql_query', 'api_call', 'browser', 'script')),
  preconditions TEXT,
  test_steps TEXT NOT NULL,
  expected_result TEXT NOT NULL,
  test_query TEXT,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'ready', 'in_progress', 'passed', 'failed', 'blocked', 'retest', 'uat_pending', 'uat_approved', 'retired')),
  priority TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('critical', 'high', 'medium', 'low')),
  last_tested_by TEXT,
  last_tested_at TIMESTAMPTZ,
  last_result TEXT CHECK (last_result IN ('pass', 'fail', 'blocked')),
  last_evidence TEXT,
  test_count INTEGER DEFAULT 0,
  retest_count INTEGER DEFAULT 0,
  current_phase TEXT DEFAULT 'qa_initial' CHECK (current_phase IN ('qa_initial', 'qa_retest_1', 'qa_retest_2', 'qa_retest_3', 'qa_final', 'uat_pending', 'uat_approved')),
  uat_signed_off_by TEXT,
  uat_signed_off_at TIMESTAMPTZ,
  uat_batch_id UUID,
  uat_notes TEXT,
  tags TEXT[],
  meta JSONB DEFAULT '{}'::jsonb,
  archived BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_test_cases_project ON test_cases (project_id);
CREATE INDEX idx_test_cases_work_item ON test_cases (work_item_id) WHERE work_item_id IS NOT NULL;
CREATE INDEX idx_test_cases_status ON test_cases (status) WHERE status NOT IN ('retired', 'uat_approved');
CREATE INDEX idx_test_cases_category ON test_cases (category);
CREATE INDEX idx_test_cases_phase ON test_cases (current_phase);
CREATE INDEX idx_test_cases_uat_batch ON test_cases (uat_batch_id) WHERE uat_batch_id IS NOT NULL;

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON test_cases
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE test_cases ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON test_cases FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON test_cases FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON test_cases FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON test_cases FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON test_cases FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE test_cases IS 'QA test case library. Each test case is a reusable verification linked to a work item. Lifecycle: draft → ready → in_progress → passed/failed → retest → uat_pending → uat_approved.';

-- TEST RUNS: immutable audit trail of every test execution
CREATE TABLE test_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  test_case_id UUID NOT NULL REFERENCES test_cases(id) ON DELETE CASCADE,
  work_item_id UUID REFERENCES work_items(id) ON DELETE SET NULL,
  executed_by TEXT NOT NULL,
  executed_at TIMESTAMPTZ DEFAULT now(),
  model_used TEXT,
  execution_context TEXT,
  result TEXT NOT NULL CHECK (result IN ('pass', 'fail', 'blocked', 'skipped')),
  phase TEXT NOT NULL,
  evidence TEXT NOT NULL,
  notes TEXT,
  duration_seconds INTEGER,
  failure_reason TEXT,
  bug_ticket_id UUID REFERENCES work_items(id),
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_test_runs_test_case ON test_runs (test_case_id);
CREATE INDEX idx_test_runs_work_item ON test_runs (work_item_id) WHERE work_item_id IS NOT NULL;
CREATE INDEX idx_test_runs_result ON test_runs (result);
CREATE INDEX idx_test_runs_executed_by ON test_runs (executed_by);
CREATE INDEX idx_test_runs_executed_at ON test_runs (executed_at DESC);

ALTER TABLE test_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON test_runs FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON test_runs FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON test_runs FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE test_runs IS 'Immutable audit trail of test executions. Every test run logged with agent/model attribution, result, evidence, and phase. Enables multi-agent QA collaboration.';

-- RPC: Batch UAT sign-off
CREATE OR REPLACE FUNCTION batch_uat_signoff(
  p_work_item_ids UUID[],
  p_signed_off_by TEXT DEFAULT 'Jason',
  p_notes TEXT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_batch_id UUID := gen_random_uuid();
  v_count INTEGER;
BEGIN
  UPDATE public.test_cases SET
    status = 'uat_approved',
    current_phase = 'uat_approved',
    uat_signed_off_by = p_signed_off_by,
    uat_signed_off_at = now(),
    uat_batch_id = v_batch_id,
    uat_notes = p_notes
  WHERE work_item_id = ANY(p_work_item_ids)
    AND status = 'uat_pending';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- RPC: Get test summary for a work item
CREATE OR REPLACE FUNCTION get_test_summary(p_work_item_id UUID)
RETURNS TABLE(total INT, passed INT, failed INT, blocked INT, uat_pending INT, uat_approved INT)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(*)::INT as total,
    COUNT(*) FILTER (WHERE status = 'passed')::INT as passed,
    COUNT(*) FILTER (WHERE status = 'failed')::INT as failed,
    COUNT(*) FILTER (WHERE status = 'blocked')::INT as blocked,
    COUNT(*) FILTER (WHERE status = 'uat_pending')::INT as uat_pending,
    COUNT(*) FILTER (WHERE status = 'uat_approved')::INT as uat_approved
  FROM public.test_cases
  WHERE work_item_id = p_work_item_id AND archived = false;
END;
$function$;;
