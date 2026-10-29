
-- SB-253: Recreate v_qa_coverage with domain column
-- Must DROP first because column order changed (domain added as first column)

DROP VIEW IF EXISTS v_qa_coverage;

CREATE VIEW v_qa_coverage AS
SELECT 
  p.domain,
  p.name AS project_name,
  p.id AS project_id,
  wi.type,
  count(*) AS total_done,
  count(*) FILTER (WHERE wi.qa_status = 'tested') AS tested,
  count(*) FILTER (WHERE wi.qa_status = 'untested') AS untested,
  count(*) FILTER (WHERE wi.qa_status = 'exempt') AS exempt,
  count(*) FILTER (WHERE wi.qa_status IS NULL) AS unclassified,
  round(CASE WHEN count(*) FILTER (WHERE wi.qa_status IN ('tested', 'untested')) > 0
    THEN count(*) FILTER (WHERE wi.qa_status = 'tested')::numeric / 
         count(*) FILTER (WHERE wi.qa_status IN ('tested', 'untested'))::numeric * 100
    ELSE 0 END, 1) AS coverage_pct
FROM work_items wi
JOIN projects p ON p.id = wi.project_id
WHERE wi.status = 'done'
GROUP BY p.id, p.domain, p.name, wi.type
ORDER BY p.name, wi.type;
;
