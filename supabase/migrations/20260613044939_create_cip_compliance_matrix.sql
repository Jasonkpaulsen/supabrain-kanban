CREATE TABLE IF NOT EXISTS public.cip_compliance_matrix (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  component_name text NOT NULL,
  component_type text NOT NULL,            -- model | library | runtime
  exact_version text,
  license_type text,
  license_url text,
  commercial_use boolean,
  redistribution boolean,
  bundling boolean,
  attribution_required text,
  sentinel_verdict text DEFAULT 'UNVERIFIED', -- CLEAR | CONDITIONAL | BLOCKED | UNVERIFIED
  obligations text,
  date_verified date,
  verified_by text,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

ALTER TABLE public.cip_compliance_matrix ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cip_compliance_matrix_owner ON public.cip_compliance_matrix;
CREATE POLICY cip_compliance_matrix_owner ON public.cip_compliance_matrix
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());;
