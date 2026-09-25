-- ============================================================
-- SB-273: Remediate wip_limits RLS vulnerability
-- Enable RLS, add policies, revoke anon access
-- ============================================================

-- 1. Enable Row Level Security
ALTER TABLE public.wip_limits ENABLE ROW LEVEL SECURITY;

-- 2. Allow all authenticated users to read WIP limits
CREATE POLICY "Allow authenticated read"
  ON public.wip_limits
  FOR SELECT
  TO authenticated
  USING (true);

-- 3. Allow only service_role to write (insert/update/delete)
CREATE POLICY "Allow service role write"
  ON public.wip_limits
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- 4. Revoke all privileges from the anon role
REVOKE ALL ON public.wip_limits FROM anon;;
