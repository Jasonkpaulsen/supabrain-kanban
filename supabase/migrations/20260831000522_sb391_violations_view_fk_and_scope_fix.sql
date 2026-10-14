
-- SB-391: V14 moves from name matching to the foreign key.
--
-- Two changes, both found by the step-0 consumer audit:
--
-- 1. SCOPE. The active_agents CTE excluded any agent whose projects are all
--    `automation_status <> 'active'`. But the runner gates on meta.dev_automation,
--    so four PMs the runner IS executing — BSC Website, Freemasons, JP Site,
--    RPG & Campaign — were outside every compliance rule. Ten agents carried the
--    identical broken reports_to value; the view reported five. Scope now counts
--    an agent in if EITHER flag says its project runs. That is strictly more
--    coverage and decides nothing: which flag is authoritative is SB-389/SB-390.
--
-- 2. V14. reports_to is now a foreign key, so "does not match any known agent"
--    is unrepresentable. The rule becomes "has no parent at all", which is the
--    condition that actually matters, and reports_to_human distinguishes the
--    legitimate root from an unset one — which the old rule could not do.
create or replace view public.vw_agent_onboarding_violations as
 WITH active_agents AS (
         SELECT a.id, a.name, a.description, a.goals, a.tags, a.meta, a.status,
                a.reports_to_agent_id, a.reports_to_human
           FROM agents a
          WHERE a.status = 'active'::text
            AND NOT (
              EXISTS (SELECT 1 FROM agent_projects ap WHERE ap.agent_id = a.id)
              AND NOT EXISTS (
                SELECT 1 FROM agent_projects ap2
                  JOIN projects p ON p.id = ap2.project_id
                 WHERE ap2.agent_id = a.id
                   AND (p.automation_status = 'active'::text
                        OR COALESCE(p.meta ->> 'dev_automation', 'off') = 'on')))
        ), checks AS (
         SELECT a.id AS agent_id, a.name AS agent_name, 'V01'::text AS rule_code,
            'Tier 1 - Universal'::text AS tier, 'name'::text AS field,
            'CRITICAL'::text AS severity, 'Agent name is missing or empty'::text AS violation
           FROM active_agents a WHERE a.name IS NULL OR TRIM(BOTH FROM a.name) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V02'::text, 'Tier 1 - Universal'::text, 'description'::text,
            'WARNING'::text, 'Agent description is missing or empty'::text
           FROM active_agents a WHERE a.description IS NULL OR TRIM(BOTH FROM a.description) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V03'::text, 'Tier 1 - Universal'::text, 'goals'::text,
            'WARNING'::text, 'Agent goals are not defined'::text
           FROM active_agents a WHERE a.goals IS NULL OR array_length(a.goals, 1) IS NULL
        UNION ALL
         SELECT a.id, a.name, 'V04'::text, 'Tier 1 - Universal'::text, 'tags'::text,
            'INFO'::text, 'Agent tags are not defined'::text
           FROM active_agents a WHERE a.tags IS NULL OR array_length(a.tags, 1) IS NULL
        UNION ALL
         SELECT a.id, a.name, 'V05'::text, 'Tier 1 - Universal'::text, 'meta.tier'::text,
            'CRITICAL'::text, 'Agent tier is not defined in meta'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR (a.meta ->> 'tier'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'tier'::text) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V06'::text, 'Tier 1 - Universal'::text, 'meta.role'::text,
            'WARNING'::text, 'Agent role is not defined in meta'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR (a.meta ->> 'role'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'role'::text) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V07'::text, 'Tier 1 - Universal'::text, 'meta.pm_assigned'::text,
            'CRITICAL'::text, 'No PM assigned to this agent'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR (a.meta ->> 'pm_assigned'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V08'::text, 'Tier 1 - Universal'::text, 'meta.escalation_path_defined'::text,
            'CRITICAL'::text, 'Escalation path not defined'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR COALESCE(a.meta ->> 'escalation_path_defined'::text, ''::text) <> 'true'::text
        UNION ALL
         SELECT a.id, a.name, 'V09'::text, 'Tier 1 - Universal'::text, 'meta.escalation_chain'::text,
            'WARNING'::text, 'Escalation chain is missing or empty'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR (a.meta -> 'escalation_chain'::text) IS NULL
             OR jsonb_typeof(a.meta -> 'escalation_chain'::text) <> 'array'::text
             OR jsonb_array_length(a.meta -> 'escalation_chain'::text) = 0
        UNION ALL
         SELECT a.id, a.name, 'V10'::text, 'Tier 1 - Universal'::text, 'meta.onboarded_date'::text,
            'WARNING'::text, 'Onboarded date not set'::text
           FROM active_agents a
          WHERE a.meta IS NULL OR (a.meta ->> 'onboarded_date'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'onboarded_date'::text) = ''::text
        UNION ALL
         SELECT a.id, a.name, 'V11'::text, 'Tier 2 - SKILL.md'::text, 'meta.file_path'::text,
            'WARNING'::text,
            concat('SKILL.md file_path not defined (required for ', COALESCE(a.meta ->> 'tier'::text, 'unknown'::text), ' tier)')
           FROM active_agents a
          WHERE a.meta IS NOT NULL AND ((a.meta ->> 'tier'::text) = ANY (ARRAY['management'::text, 'system'::text, 'apex'::text]))
            AND ((a.meta ->> 'file_path'::text) IS NULL OR TRIM(BOTH FROM a.meta ->> 'file_path'::text) = ''::text)
        UNION ALL
         SELECT a.id, a.name, 'V12'::text, 'Tier 3 - Project Linkage'::text, 'agent_projects'::text,
            'INFO'::text, 'Agent has no project assignments (system/apex exempt)'::text
           FROM active_agents a
          WHERE (COALESCE(a.meta ->> 'tier'::text, ''::text) <> ALL (ARRAY['system'::text, 'apex'::text]))
            AND NOT (EXISTS (SELECT 1 FROM agent_projects ap WHERE ap.agent_id = a.id))
        UNION ALL
         SELECT a.id, a.name, 'V13'::text, 'Tier 4 - Referential Integrity'::text, 'meta.pm_assigned'::text,
            'CRITICAL'::text,
            concat('pm_assigned [', a.meta ->> 'pm_assigned'::text, '] does not match any known agent')
           FROM active_agents a
          WHERE (a.meta ->> 'pm_assigned'::text) IS NOT NULL AND TRIM(BOTH FROM a.meta ->> 'pm_assigned'::text) <> ''::text
            AND COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text
            AND NOT (EXISTS (SELECT 1 FROM agents ref WHERE ref.name = (a.meta ->> 'pm_assigned'::text)))
        UNION ALL
         SELECT a.id, a.name, 'V14'::text, 'Tier 4 - Referential Integrity'::text, 'reports_to_agent_id'::text,
            'CRITICAL'::text, 'No reporting line set (reports_to_agent_id and reports_to_human both null)'::text
           FROM active_agents a
          WHERE a.reports_to_agent_id IS NULL
            AND a.reports_to_human IS NULL
            AND COALESCE(a.meta ->> 'tier'::text, ''::text) <> 'apex'::text
            AND NOT COALESCE((a.meta ->> 'qa_fixture'::text)::boolean, false)
        )
 SELECT agent_id, agent_name, rule_code, tier, field, severity, violation
   FROM checks
  ORDER BY agent_name, rule_code;
;
