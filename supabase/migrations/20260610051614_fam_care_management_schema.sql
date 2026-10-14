-- ============================================================
-- Family/Kids Care Management schema (FAM-003/004/005/006 + FAM-007 baseline)
-- All tables: standard columns, updated_at trigger, FK indexes, RLS (owner + project members).
-- child_project_id references the child's family sub-project (Kai/Jai) or the family hub.
-- ============================================================

-- ---- Write-audit log + trigger function (FAM-007) ----
CREATE TABLE IF NOT EXISTS public.care_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  table_name text NOT NULL,
  row_id uuid,
  action text NOT NULL CHECK (action IN ('insert','update','delete')),
  child_project_id uuid,
  occurred_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.care_audit_log ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.fn_care_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_row_id uuid;
  v_child uuid;
BEGIN
  IF (TG_OP = 'DELETE') THEN
    v_row_id := OLD.id; v_child := OLD.child_project_id;
  ELSE
    v_row_id := NEW.id; v_child := NEW.child_project_id;
  END IF;
  INSERT INTO public.care_audit_log(actor_id, table_name, row_id, action, child_project_id)
  VALUES ((SELECT auth.uid()), TG_TABLE_NAME, v_row_id, lower(TG_OP), v_child);
  RETURN NULL;
END;
$$;

-- ---- 1. health_providers ----
CREATE TABLE IF NOT EXISTS public.health_providers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  name text NOT NULL,
  specialty text,
  organization text,
  phone text,
  email text,
  portal_url text,
  portal_secret_ref text,            -- Vault secret name, never a plaintext credential
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 2. health_events ----
CREATE TABLE IF NOT EXISTS public.health_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  provider_id uuid REFERENCES public.health_providers(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN ('appointment','visit','diagnosis','lab','other')),
  event_date date,
  summary text,
  follow_up text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 3. medications ----
CREATE TABLE IF NOT EXISTS public.medications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  name text NOT NULL,
  dose text,
  schedule text,
  prescriber_provider_id uuid REFERENCES public.health_providers(id) ON DELETE SET NULL,
  start_date date,
  end_date date,
  refill_due date,
  pharmacy text,
  adherence_notes text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 4. care_plans ----
CREATE TABLE IF NOT EXISTS public.care_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  plan_type text NOT NULL CHECK (plan_type IN ('therapy','iep','504','behavioral','other')),
  goals text,
  accommodations text,
  provider_id uuid REFERENCES public.health_providers(id) ON DELETE SET NULL,
  review_date date,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 5. behavioral_logs ----
CREATE TABLE IF NOT EXISTS public.behavioral_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  log_date date NOT NULL DEFAULT current_date,
  context text,
  trigger text,
  response text,
  what_worked text,
  tags text[],
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 6. activities (non-PHI) ----
CREATE TABLE IF NOT EXISTS public.activities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  name text NOT NULL,
  activity_type text,
  location text,
  cadence text,
  contact_name text,
  contact_info text,
  season text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- 7. family_events (non-PHI) ----
CREATE TABLE IF NOT EXISTS public.family_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  child_project_id uuid REFERENCES public.projects(id) ON DELETE CASCADE,  -- nullable = family-wide (use hub id to share)
  title text NOT NULL,
  event_type text NOT NULL DEFAULT 'other' CHECK (event_type IN ('appointment','activity','school','other')),
  starts_at timestamptz,
  ends_at timestamptz,
  location text,
  source text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','calendar_mcp','school_monitor')),
  external_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- updated_at triggers
-- ============================================================
CREATE TRIGGER trg_health_providers_updated BEFORE UPDATE ON public.health_providers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_health_events_updated    BEFORE UPDATE ON public.health_events    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_medications_updated      BEFORE UPDATE ON public.medications      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_care_plans_updated       BEFORE UPDATE ON public.care_plans       FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_behavioral_logs_updated  BEFORE UPDATE ON public.behavioral_logs  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_activities_updated       BEFORE UPDATE ON public.activities       FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_family_events_updated    BEFORE UPDATE ON public.family_events    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================================
-- write-audit triggers (PHI care tables only: 1-5)
-- ============================================================
CREATE TRIGGER trg_health_providers_audit AFTER INSERT OR UPDATE OR DELETE ON public.health_providers FOR EACH ROW EXECUTE FUNCTION public.fn_care_audit();
CREATE TRIGGER trg_health_events_audit    AFTER INSERT OR UPDATE OR DELETE ON public.health_events    FOR EACH ROW EXECUTE FUNCTION public.fn_care_audit();
CREATE TRIGGER trg_medications_audit      AFTER INSERT OR UPDATE OR DELETE ON public.medications      FOR EACH ROW EXECUTE FUNCTION public.fn_care_audit();
CREATE TRIGGER trg_care_plans_audit       AFTER INSERT OR UPDATE OR DELETE ON public.care_plans       FOR EACH ROW EXECUTE FUNCTION public.fn_care_audit();
CREATE TRIGGER trg_behavioral_logs_audit  AFTER INSERT OR UPDATE OR DELETE ON public.behavioral_logs  FOR EACH ROW EXECUTE FUNCTION public.fn_care_audit();

-- ============================================================
-- FK / query indexes
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_health_providers_child ON public.health_providers(child_project_id);
CREATE INDEX IF NOT EXISTS idx_health_providers_user  ON public.health_providers(user_id);
CREATE INDEX IF NOT EXISTS idx_health_events_child    ON public.health_events(child_project_id);
CREATE INDEX IF NOT EXISTS idx_health_events_provider ON public.health_events(provider_id);
CREATE INDEX IF NOT EXISTS idx_health_events_user     ON public.health_events(user_id);
CREATE INDEX IF NOT EXISTS idx_medications_child      ON public.medications(child_project_id);
CREATE INDEX IF NOT EXISTS idx_medications_prescriber ON public.medications(prescriber_provider_id);
CREATE INDEX IF NOT EXISTS idx_medications_refill_due ON public.medications(refill_due) WHERE active;
CREATE INDEX IF NOT EXISTS idx_medications_user       ON public.medications(user_id);
CREATE INDEX IF NOT EXISTS idx_care_plans_child       ON public.care_plans(child_project_id);
CREATE INDEX IF NOT EXISTS idx_care_plans_provider    ON public.care_plans(provider_id);
CREATE INDEX IF NOT EXISTS idx_care_plans_review      ON public.care_plans(review_date) WHERE status='active';
CREATE INDEX IF NOT EXISTS idx_care_plans_user        ON public.care_plans(user_id);
CREATE INDEX IF NOT EXISTS idx_behavioral_logs_child  ON public.behavioral_logs(child_project_id);
CREATE INDEX IF NOT EXISTS idx_behavioral_logs_user   ON public.behavioral_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_activities_child       ON public.activities(child_project_id);
CREATE INDEX IF NOT EXISTS idx_activities_user        ON public.activities(user_id);
CREATE INDEX IF NOT EXISTS idx_family_events_child    ON public.family_events(child_project_id);
CREATE INDEX IF NOT EXISTS idx_family_events_starts   ON public.family_events(starts_at);
CREATE INDEX IF NOT EXISTS idx_family_events_user     ON public.family_events(user_id);
CREATE INDEX IF NOT EXISTS idx_care_audit_child       ON public.care_audit_log(child_project_id);
CREATE INDEX IF NOT EXISTS idx_care_audit_actor       ON public.care_audit_log(actor_id);

-- ============================================================
-- RLS: enable + owner-or-project-member policy on every data table
-- ============================================================
ALTER TABLE public.health_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health_events    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medications      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_plans       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.behavioral_logs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activities       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_events    ENABLE ROW LEVEL SECURITY;

-- health_providers
CREATE POLICY hp_access ON public.health_providers FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=health_providers.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=health_providers.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=health_providers.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=health_providers.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- health_events
CREATE POLICY he_access ON public.health_events FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=health_events.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=health_events.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=health_events.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=health_events.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- medications
CREATE POLICY med_access ON public.medications FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=medications.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=medications.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=medications.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=medications.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- care_plans
CREATE POLICY cp_access ON public.care_plans FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=care_plans.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=care_plans.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=care_plans.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=care_plans.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- behavioral_logs
CREATE POLICY bl_access ON public.behavioral_logs FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=behavioral_logs.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=behavioral_logs.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=behavioral_logs.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=behavioral_logs.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- activities
CREATE POLICY act_access ON public.activities FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=activities.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=activities.child_project_id AND pr.user_id=(SELECT auth.uid())))
WITH CHECK (user_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=activities.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=activities.child_project_id AND pr.user_id=(SELECT auth.uid())));

-- family_events (nullable child_project_id: owner always; members when scoped to a project)
CREATE POLICY fe_access ON public.family_events FOR ALL TO authenticated
USING (user_id=(SELECT auth.uid())
  OR (child_project_id IS NOT NULL AND (
       EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=family_events.child_project_id AND pm.user_id=(SELECT auth.uid()))
    OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=family_events.child_project_id AND pr.user_id=(SELECT auth.uid())))))
WITH CHECK (user_id=(SELECT auth.uid())
  OR (child_project_id IS NOT NULL AND (
       EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=family_events.child_project_id AND pm.user_id=(SELECT auth.uid()))
    OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=family_events.child_project_id AND pr.user_id=(SELECT auth.uid())))));

-- care_audit_log: read-only to owner/members; writes only via SECURITY DEFINER trigger
CREATE POLICY cal_read ON public.care_audit_log FOR SELECT TO authenticated
USING (actor_id=(SELECT auth.uid())
  OR EXISTS(SELECT 1 FROM public.project_members pm WHERE pm.project_id=care_audit_log.child_project_id AND pm.user_id=(SELECT auth.uid()))
  OR EXISTS(SELECT 1 FROM public.projects pr WHERE pr.id=care_audit_log.child_project_id AND pr.user_id=(SELECT auth.uid())));;
