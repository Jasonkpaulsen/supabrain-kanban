
-- Drop overly permissive "always true" policies and replace with service_role-only policies.
-- This ensures only the service_role key (backend) can access data, not anon or authenticated keys.

-- profiles
DROP POLICY IF EXISTS "Service role full access" ON public.profiles;
CREATE POLICY "Service role full access" ON public.profiles
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- projects
DROP POLICY IF EXISTS "Service role full access" ON public.projects;
CREATE POLICY "Service role full access" ON public.projects
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- memories
DROP POLICY IF EXISTS "Service role full access" ON public.memories;
CREATE POLICY "Service role full access" ON public.memories
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- reference_items
DROP POLICY IF EXISTS "Service role full access" ON public.reference_items;
CREATE POLICY "Service role full access" ON public.reference_items
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- decisions
DROP POLICY IF EXISTS "Service role full access" ON public.decisions;
CREATE POLICY "Service role full access" ON public.decisions
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- image_assets
DROP POLICY IF EXISTS "Service role full access" ON public.image_assets;
CREATE POLICY "Service role full access" ON public.image_assets
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- conversations
DROP POLICY IF EXISTS "Service role full access" ON public.conversations;
CREATE POLICY "Service role full access" ON public.conversations
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- job_applications: had "Allow all for authenticated users"
DROP POLICY IF EXISTS "Allow all for authenticated users" ON public.job_applications;
CREATE POLICY "Service role full access" ON public.job_applications
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);
;
