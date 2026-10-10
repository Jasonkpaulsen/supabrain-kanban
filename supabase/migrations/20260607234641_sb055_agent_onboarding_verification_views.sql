
-- SB-055: Agent Onboarding Verification Mechanism
-- Two views implementing 14 rules across 4 tiers
-- Flag-don't-block philosophy: CRITICAL / WARNING / INFO severity

CREATE OR REPLACE VIEW vw_agent_onboarding_violations AS
WITH active_agents AS (
  SELECT id, name, description, goals, tags, meta, status
  FROM agents
  WHERE status = 'active'
),
checks AS (
  SELECT a.id AS agent_id, a.name AS agent_name,
         'V01' AS rule_code, 'Tier 1 - Universal' AS tier,
         'name' AS field, 'CRITICAL' AS severity,
         'Agent name is missing or empty' AS violation
  FROM active_agents a
  WHERE a.name IS NULL OR trim(a.name) = ''

  UNION ALL

  SELECT a.id, a.name, 'V02', 'Tier 1 - Universal', 'description', 'WARNING',
         'Agent description is missing or empty'
  FROM active_agents a
  WHERE a.description IS NULL OR trim(a.description) = ''

  UNION ALL

  SELECT a.id, a.name, 'V03', 'Tier 1 - Universal', 'goals', 'WARNING',
         'Agent goals are not defined'
  FROM active_agents a
  WHERE a.goals IS NULL OR array_length(a.goals, 1) IS NULL

  UNION ALL

  SELECT a.id, a.name, 'V04', 'Tier 1 - Universal', 'tags', 'INFO',
         'Agent tags are not defined'
  FROM active_agents a
  WHERE a.tags IS NULL OR array_length(a.tags, 1) IS NULL

  UNION ALL

  SELECT a.id, a.name, 'V05', 'Tier 1 - Universal', 'meta.tier', 'CRITICAL',
         'Agent tier is not defined in meta'
  FROM active_agents a
  WHERE a.meta IS NULL OR a.meta->>'tier' IS NULL OR trim(a.meta->>'tier') = ''

  UNION ALL

  SELECT a.id, a.name, 'V06', 'Tier 1 - Universal', 'meta.role', 'WARNING',
         'Agent role is not defined in meta'
  FROM active_agents a
  WHERE a.meta IS NULL OR a.meta->>'role' IS NULL OR trim(a.meta->>'role') = ''

  UNION ALL

  SELECT a.id, a.name, 'V07', 'Tier 1 - Universal', 'meta.pm_assigned', 'CRITICAL',
         'No PM assigned to this agent'
  FROM active_agents a
  WHERE a.meta IS NULL OR a.meta->>'pm_assigned' IS NULL OR trim(a.meta->>'pm_assigned') = ''

  UNION ALL

  SELECT a.id, a.name, 'V08', 'Tier 1 - Universal', 'meta.escalation_path_defined', 'CRITICAL',
         'Escalation path not defined'
  FROM active_agents a
  WHERE a.meta IS NULL OR COALESCE(a.meta->>'escalation_path_defined', '') != 'true'

  UNION ALL

  SELECT a.id, a.name, 'V09', 'Tier 1 - Universal', 'meta.escalation_chain', 'WARNING',
         'Escalation chain is missing or empty'
  FROM active_agents a
  WHERE a.meta IS NULL
     OR a.meta->'escalation_chain' IS NULL
     OR jsonb_typeof(a.meta->'escalation_chain') != 'array'
     OR jsonb_array_length(a.meta->'escalation_chain') = 0

  UNION ALL

  SELECT a.id, a.name, 'V10', 'Tier 1 - Universal', 'meta.onboarded_date', 'WARNING',
         'Onboarded date not set'
  FROM active_agents a
  WHERE a.meta IS NULL OR a.meta->>'onboarded_date' IS NULL OR trim(a.meta->>'onboarded_date') = ''

  UNION ALL

  SELECT a.id, a.name, 'V11', 'Tier 2 - SKILL.md', 'meta.file_path', 'WARNING',
         concat('SKILL.md file_path not defined (required for ', COALESCE(a.meta->>'tier', 'unknown'), ' tier)')
  FROM active_agents a
  WHERE a.meta IS NOT NULL
    AND a.meta->>'tier' IN ('management', 'system', 'apex')
    AND (a.meta->>'file_path' IS NULL OR trim(a.meta->>'file_path') = '')

  UNION ALL

  SELECT a.id, a.name, 'V12', 'Tier 3 - Project Linkage', 'agent_projects', 'INFO',
         'Agent has no project assignments (system/apex exempt)'
  FROM active_agents a
  WHERE COALESCE(a.meta->>'tier', '') NOT IN ('system', 'apex')
    AND NOT EXISTS (SELECT 1 FROM agent_projects ap WHERE ap.agent_id = a.id)

  UNION ALL

  SELECT a.id, a.name, 'V13', 'Tier 4 - Referential Integrity', 'meta.pm_assigned', 'CRITICAL',
         concat('pm_assigned [', a.meta->>'pm_assigned', '] does not match any known agent')
  FROM active_agents a
  WHERE a.meta->>'pm_assigned' IS NOT NULL
    AND trim(a.meta->>'pm_assigned') != ''
    AND NOT EXISTS (SELECT 1 FROM agents ref WHERE ref.name = a.meta->>'pm_assigned')

  UNION ALL

  SELECT a.id, a.name, 'V14', 'Tier 4 - Referential Integrity', 'meta.reports_to', 'CRITICAL',
         concat('reports_to [', a.meta->>'reports_to', '] does not match any known agent')
  FROM active_agents a
  WHERE a.meta IS NOT NULL
    AND jsonb_typeof(a.meta->'reports_to') = 'string'
    AND trim(a.meta->>'reports_to') != ''
    AND NOT EXISTS (SELECT 1 FROM agents ref WHERE ref.name = a.meta->>'reports_to')

  UNION ALL

  SELECT a.id, a.name, 'V14', 'Tier 4 - Referential Integrity', 'meta.reports_to', 'CRITICAL',
         concat('reports_to contains [', elem.value, '] which does not match any known agent')
  FROM active_agents a,
       LATERAL jsonb_array_elements_text(a.meta->'reports_to') AS elem(value)
  WHERE a.meta IS NOT NULL
    AND jsonb_typeof(a.meta->'reports_to') = 'array'
    AND NOT EXISTS (SELECT 1 FROM agents ref WHERE ref.name = elem.value)
)
SELECT * FROM checks
ORDER BY agent_name, rule_code;

-- Summary view: one row per active agent with PASS/WARN/FAIL
CREATE OR REPLACE VIEW vw_agent_onboarding_summary AS
WITH violation_counts AS (
  SELECT
    agent_id,
    agent_name,
    count(*) FILTER (WHERE severity = 'CRITICAL') AS critical_count,
    count(*) FILTER (WHERE severity = 'WARNING') AS warning_count,
    count(*) FILTER (WHERE severity = 'INFO') AS info_count,
    count(*) AS total_violations
  FROM vw_agent_onboarding_violations
  GROUP BY agent_id, agent_name
)
SELECT
  a.id AS agent_id,
  a.name AS agent_name,
  COALESCE(a.meta->>'tier', 'unknown') AS agent_tier,
  COALESCE(a.meta->>'pm_assigned', '-') AS pm_assigned,
  CASE
    WHEN vc.critical_count > 0 THEN 'FAIL'
    WHEN vc.warning_count > 0 THEN 'WARN'
    WHEN vc.info_count > 0 THEN 'INFO'
    ELSE 'PASS'
  END AS onboarding_status,
  COALESCE(vc.critical_count, 0) AS critical_count,
  COALESCE(vc.warning_count, 0) AS warning_count,
  COALESCE(vc.info_count, 0) AS info_count,
  COALESCE(vc.total_violations, 0) AS total_violations
FROM agents a
LEFT JOIN violation_counts vc ON vc.agent_id = a.id
WHERE a.status = 'active'
ORDER BY
  CASE
    WHEN vc.critical_count > 0 THEN 1
    WHEN vc.warning_count > 0 THEN 2
    WHEN vc.info_count > 0 THEN 3
    ELSE 4
  END,
  a.name;
;
