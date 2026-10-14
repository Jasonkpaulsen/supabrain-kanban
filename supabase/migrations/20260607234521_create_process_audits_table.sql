-- SB-053: Create process_audits table for PE trend tracking
-- Designed by: System Architect (2026-06-07)

CREATE TABLE public.process_audits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  auditor_agent_id uuid REFERENCES public.agents(id) ON DELETE SET NULL,

  -- Audit identification
  audit_type text NOT NULL DEFAULT 'daily',
  audit_date date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'completed',

  -- Core JSONB audit data
  governance_violations jsonb NOT NULL DEFAULT '[]'::jsonb,
  flow_metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
  agent_utilization jsonb NOT NULL DEFAULT '{}'::jsonb,
  qa_coverage_stats jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Scalar summaries for fast querying
  recommendations_count integer NOT NULL DEFAULT 0,
  flags_count integer NOT NULL DEFAULT 0,
  violations_count integer NOT NULL DEFAULT 0,
  max_severity text DEFAULT NULL,

  -- Soft-link arrays for cross-referencing
  related_ticket_codes text[] DEFAULT '{}'::text[],
  related_agent_ids uuid[] DEFAULT '{}'::uuid[],
  related_skill_ids uuid[] DEFAULT '{}'::uuid[],

  -- Flexible metadata
  meta jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Timestamps
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),

  -- Unique constraint: one audit per project/type/date
  CONSTRAINT process_audits_unique_daily UNIQUE (project_id, audit_type, audit_date)
);

-- Comment
COMMENT ON TABLE public.process_audits IS 'Process Engineer audit results — one row per audit run with governance violations, flow metrics, agent utilization, and QA coverage. Enables trend analysis across days.';

-- Indexes (6 total)
CREATE INDEX idx_process_audits_user_id ON public.process_audits(user_id);
CREATE INDEX idx_process_audits_project_id ON public.process_audits(project_id);
CREATE INDEX idx_process_audits_auditor_agent_id ON public.process_audits(auditor_agent_id);
CREATE INDEX idx_process_audits_audit_date ON public.process_audits(audit_date DESC);
CREATE INDEX idx_process_audits_audit_type ON public.process_audits(audit_type);
CREATE INDEX idx_process_audits_max_severity ON public.process_audits(max_severity) WHERE max_severity IS NOT NULL;

-- Updated_at trigger
CREATE TRIGGER set_process_audits_updated_at
  BEFORE UPDATE ON public.process_audits
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

-- Enable RLS
ALTER TABLE public.process_audits ENABLE ROW LEVEL SECURITY;

-- RLS Policies (matching existing patterns)
CREATE POLICY "service_role_full" ON public.process_audits
  FOR ALL TO service_role USING (true) WITH CHECK (true);

CREATE POLICY "users_select_own" ON public.process_audits
  FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "users_insert_own" ON public.process_audits
  FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "users_update_own" ON public.process_audits
  FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "users_delete_own" ON public.process_audits
  FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);;
