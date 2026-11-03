
-- SB-272: Reconcile PE QA-coverage metric
-- Canonical method: test_cases JOIN is ground truth.
-- A done work_item is "tested" if it has ≥1 linked test_case row (any status).
-- The qa_status column is a convenience cache set by enforce_qa_gate on transition;
-- v_qa_coverage_authoritative is the authoritative source that re-derives from test_cases.

CREATE OR REPLACE VIEW public.v_qa_coverage_authoritative AS
WITH done_items AS (
  SELECT
    wi.id,
    wi.project_id,
    wi.type,
    wi.qa_status AS cached_qa_status,
    CASE
      -- Exempt types and non-engineering domains stay exempt
      WHEN wi.qa_status = 'exempt' THEN 'exempt'
      -- Derive from actual test_cases linkage
      WHEN EXISTS (SELECT 1 FROM public.test_cases tc WHERE tc.work_item_id = wi.id) THEN 'tested'
      ELSE 'untested'
    END AS authoritative_qa_status,
    CASE
      WHEN wi.qa_status = 'exempt' THEN false
      WHEN wi.qa_status IS DISTINCT FROM
        CASE
          WHEN EXISTS (SELECT 1 FROM public.test_cases tc WHERE tc.work_item_id = wi.id) THEN 'tested'
          ELSE 'untested'
        END
      THEN true
      ELSE false
    END AS is_stale
  FROM public.work_items wi
  WHERE wi.status = 'done'
)
SELECT
  p.domain,
  p.name AS project_name,
  p.id AS project_id,
  di.type,
  count(*) AS total_done,
  count(*) FILTER (WHERE di.authoritative_qa_status = 'tested') AS tested,
  count(*) FILTER (WHERE di.authoritative_qa_status = 'untested') AS untested,
  count(*) FILTER (WHERE di.authoritative_qa_status = 'exempt') AS exempt,
  count(*) FILTER (WHERE di.is_stale) AS stale_cache_count,
  round(
    CASE
      WHEN count(*) FILTER (WHERE di.authoritative_qa_status IN ('tested','untested')) > 0
      THEN count(*) FILTER (WHERE di.authoritative_qa_status = 'tested')::numeric
           / count(*) FILTER (WHERE di.authoritative_qa_status IN ('tested','untested'))::numeric * 100
      ELSE 0
    END, 1
  ) AS coverage_pct
FROM done_items di
JOIN public.projects p ON p.id = di.project_id
GROUP BY p.id, p.domain, p.name, di.type
ORDER BY p.name, di.type;

COMMENT ON VIEW public.v_qa_coverage_authoritative IS
  'SB-272: Authoritative QA coverage. Derives tested/untested from test_cases JOIN (ground truth), not the cached qa_status column. The stale_cache_count column shows how many items have a qa_status that disagrees with reality.';
;
