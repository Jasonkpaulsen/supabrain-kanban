-- Add RLS policies for authenticated users on all tables
-- These allow any logged-in user full CRUD access

-- profiles
CREATE POLICY "Authenticated users full access" ON public.profiles
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- projects
CREATE POLICY "Authenticated users full access" ON public.projects
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- decisions
CREATE POLICY "Authenticated users full access" ON public.decisions
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- memories
CREATE POLICY "Authenticated users full access" ON public.memories
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- conversations
CREATE POLICY "Authenticated users full access" ON public.conversations
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- reference_items
CREATE POLICY "Authenticated users full access" ON public.reference_items
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- image_assets
CREATE POLICY "Authenticated users full access" ON public.image_assets
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- job_applications
CREATE POLICY "Authenticated users full access" ON public.job_applications
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
;
