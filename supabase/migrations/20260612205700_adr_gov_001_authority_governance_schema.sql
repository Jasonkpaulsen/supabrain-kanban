-- ADR-GOV-001 / SB-171: Decision-authority governance schema

-- 1. Authority levels reference table
CREATE TABLE IF NOT EXISTS authority_levels (
  level int PRIMARY KEY CHECK (level BETWEEN 0 AND 4),
  name text NOT NULL UNIQUE,
  stop_required boolean NOT NULL,
  requires_jason boolean NOT NULL,
  description text
);

INSERT INTO authority_levels (level, name, stop_required, requires_jason, description) VALUES
 (0,'autonomous',false,false,'Execute without approval. Research, analysis, drafts, monitoring, routine maintenance. No ticket unless output feeds another agent; telemetry to agent_runs.'),
 (1,'notify',false,false,'Proceed automatically; inform Jason afterward via daily briefing. Ticket created and closed in same run with meta.governance.notified=true. Excludes governance/schema changes.'),
 (2,'recommend',true,false,'Stop and present decision package (recommendation, alternatives, benefits, risks, confidence). Jason chooses. Status awaiting_jason until decided.'),
 (3,'approval',true,true,'Hard stop BEFORE any work. Requires approval_status=approved AND approved_by=jason to proceed.'),
 (4,'executive',true,true,'Jason sole authority, non-delegable. JARVIS may never auto-resolve. Includes changes to Jarvis governance itself.')
ON CONFLICT (level) DO NOTHING;

-- 2. Action category -> level mapping (global source of truth)
CREATE TABLE IF NOT EXISTS authority_action_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_category text NOT NULL UNIQUE,
  default_level int NOT NULL REFERENCES authority_levels(level),
  escalation_triggers text[] NOT NULL DEFAULT '{}',
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO authority_action_map (action_category, default_level, escalation_triggers, notes) VALUES
 ('research',0,'{}','Web/data research, source comparison'),
 ('analysis',0,'{}','Data analysis, metrics, pattern detection'),
 ('documentation',0,'{}','Writing/organizing internal docs'),
 ('data_collection',0,'{}','Scraping, ingestion, parsing within approved scope'),
 ('draft_writing',0,'{}','Draft content not yet published anywhere'),
 ('ticket_creation',0,'{}','Creating work_items per lifecycle rules'),
 ('code_generation',0,'{}','Writing code not yet deployed'),
 ('knowledge_organization',0,'{}','Memories, reference items, knowledge bases'),
 ('reporting',0,'{}','Reports, briefings, retrospectives'),
 ('monitoring',0,'{}','Sweeps, audits, health checks; log to agent_runs not board'),
 ('routine_maintenance',0,'{}','Pre-authorized recurring upkeep'),
 ('notification',0,'{}','Sending internal notifications'),
 ('workflow_execution',0,'{}','Running an already-approved workflow'),
 ('engineering_execution',1,'{}','Completing approved engineering work'),
 ('doc_update',1,'{}','Updating existing documentation'),
 ('project_plan',1,'{}','Creating/updating project plans'),
 ('ticket_closure',1,'{}','Closing completed tickets'),
 ('database_update',1,'{}','Routine data updates within approved scope. NOT schema changes.'),
 ('internal_publishing',1,'{}','Publishing internal knowledge'),
 ('test_execution',1,'{}','Running test suites, logging test_runs'),
 ('technical_approach_selection',2,'{conflicting_recommendations}','Selecting between technical approaches'),
 ('vendor_selection',2,'{financial}','Choosing vendors/services'),
 ('workflow_design',2,'{}','Designing new workflows'),
 ('architecture_change',2,'{cross_domain}','Significant architectural changes'),
 ('new_automation',2,'{irreversible}','Creating new automations/scheduled runs'),
 ('schema_change_minor',2,'{}','Additive schema changes (new tables/columns); PE chain applies'),
 ('agent_config_change',2,'{}','Changing agent definitions, prompts, scope'),
 ('process_change',2,'{}','Changes to operational processes; PE chain applies'),
 ('financial_transaction',3,'{financial,irreversible}','Any movement of money'),
 ('banking_connection',3,'{financial,security}','Connecting bank/financial accounts'),
 ('purchase',3,'{financial}','Purchases of any size'),
 ('public_communication',3,'{public_comms,reputation_risk}','Anything visible outside the ecosystem'),
 ('external_commitment',3,'{legal,reputation_risk}','Commitments to external parties'),
 ('production_deployment',3,'{irreversible}','Deploying to production'),
 ('credential_change',3,'{security}','Creating/rotating/sharing credentials'),
 ('data_deletion',3,'{irreversible}','Destructive data operations'),
 ('security_policy_change',3,'{security}','RLS, auth, access policy changes'),
 ('ai_model_change',3,'{}','Changing AI models in any pipeline'),
 ('third_party_integration',3,'{security,privacy}','New external integrations/MCPs'),
 ('schema_change_breaking',3,'{irreversible,cross_domain}','Breaking schema changes to shared infrastructure'),
 ('project_strategy',4,'{}','Project strategy and direction'),
 ('long_term_priorities',4,'{}','Long-term priority setting'),
 ('ethical_decision',4,'{ethical}','Ethical judgment calls'),
 ('legal_matter',4,'{legal}','Legal issues'),
 ('privacy_matter',4,'{privacy}','Privacy decisions incl. family data'),
 ('personal_matter',4,'{privacy}','Personal/family matters'),
 ('hiring',4,'{financial}','Hiring of any kind'),
 ('large_expenditure',4,'{financial}','Large spend (threshold: Jason-defined)'),
 ('multi_domain_change',4,'{cross_domain}','Changes affecting multiple domains'),
 ('governance_change',4,'{}','Changes to Jarvis governance itself — non-delegable')
ON CONFLICT (action_category) DO NOTHING;

-- 3. Immutable governance audit ledger
CREATE TABLE IF NOT EXISTS governance_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT '5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
  work_item_id uuid REFERENCES work_items(id) ON DELETE SET NULL,
  from_status text,
  to_status text,
  authority_level int REFERENCES authority_levels(level),
  action_category text,
  decided_by text NOT NULL,
  decision text NOT NULL CHECK (decision IN ('approved','rejected','auto','deferred','escalated','notified')),
  confidence numeric,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 4. RLS: reference tables read-only; audit insert-only
ALTER TABLE authority_levels ENABLE ROW LEVEL SECURITY;
CREATE POLICY authority_levels_read ON authority_levels FOR SELECT TO authenticated USING (true);
ALTER TABLE authority_action_map ENABLE ROW LEVEL SECURITY;
CREATE POLICY authority_action_map_read ON authority_action_map FOR SELECT TO authenticated USING (true);
ALTER TABLE governance_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY governance_audit_select ON governance_audit FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY governance_audit_insert ON governance_audit FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
-- no UPDATE/DELETE policies = immutable for authenticated role
REVOKE UPDATE, DELETE ON governance_audit FROM authenticated, anon;

-- 5. Gating columns (real columns, not meta — trigger/RLS enforceable)
ALTER TABLE work_items ADD COLUMN IF NOT EXISTS authority_level int REFERENCES authority_levels(level);
ALTER TABLE work_items ADD COLUMN IF NOT EXISTS action_category text REFERENCES authority_action_map(action_category);
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS work_item_id uuid REFERENCES work_items(id) ON DELETE SET NULL;

-- 6. awaiting_jason status (human boundary, distinct from escalated)
ALTER TABLE work_items DROP CONSTRAINT work_items_status_check;
ALTER TABLE work_items ADD CONSTRAINT work_items_status_check CHECK (status = ANY (ARRAY['backlog'::text,'todo'::text,'in_progress'::text,'review'::text,'done'::text,'escalated'::text,'blocked'::text,'on_hold'::text,'awaiting_jason'::text]));

CREATE INDEX IF NOT EXISTS idx_work_items_awaiting_jason ON work_items (status) WHERE status = 'awaiting_jason';
CREATE INDEX IF NOT EXISTS idx_governance_audit_work_item ON governance_audit (work_item_id);;
