
-- Session 3 migration: Replace permissive USING (true) RLS policies with
-- auth.uid() = user_id scoping. Preserves service_role "full access" policies.
-- Skill: tech-supabase-security (six-step retrofit pattern applied per table)
--
-- Jason's auth.users.id for backfill: 5ecbd44a-a3e2-4363-9133-dff3851ba0f5
-- Total rows backfilled: ~460 across 11 tables.
-- Default user_id = auth.uid() on every new insert going forward.

-- ============================================================================
-- 1. conversations (12 rows)
-- ============================================================================
ALTER TABLE public.conversations ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.conversations
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.conversations
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.conversations
  ADD CONSTRAINT conversations_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.conversations;
CREATE POLICY "users_select_own" ON public.conversations
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.conversations
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.conversations
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.conversations
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_conversations_user_id ON public.conversations(user_id);

-- ============================================================================
-- 2. decisions (56 rows)
-- ============================================================================
ALTER TABLE public.decisions ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.decisions
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.decisions
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.decisions
  ADD CONSTRAINT decisions_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.decisions;
CREATE POLICY "users_select_own" ON public.decisions
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.decisions
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.decisions
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.decisions
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_decisions_user_id ON public.decisions(user_id);

-- ============================================================================
-- 3. memories (74 rows)
-- ============================================================================
ALTER TABLE public.memories ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.memories
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.memories
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.memories
  ADD CONSTRAINT memories_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.memories;
CREATE POLICY "users_select_own" ON public.memories
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.memories
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.memories
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.memories
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_memories_user_id ON public.memories(user_id);

-- ============================================================================
-- 4. projects (24 rows)
-- ============================================================================
ALTER TABLE public.projects ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.projects
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.projects
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.projects
  ADD CONSTRAINT projects_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.projects;
CREATE POLICY "users_select_own" ON public.projects
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.projects
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.projects
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.projects
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON public.projects(user_id);

-- ============================================================================
-- 5. reference_items (15 rows)
-- ============================================================================
ALTER TABLE public.reference_items ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.reference_items
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.reference_items
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.reference_items
  ADD CONSTRAINT reference_items_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.reference_items;
CREATE POLICY "users_select_own" ON public.reference_items
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.reference_items
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.reference_items
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.reference_items
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_reference_items_user_id ON public.reference_items(user_id);

-- ============================================================================
-- 6. image_assets (3 rows)
-- ============================================================================
ALTER TABLE public.image_assets ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.image_assets
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.image_assets
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.image_assets
  ADD CONSTRAINT image_assets_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.image_assets;
CREATE POLICY "users_select_own" ON public.image_assets
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.image_assets
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.image_assets
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.image_assets
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_image_assets_user_id ON public.image_assets(user_id);

-- ============================================================================
-- 7. job_applications (119 rows)
-- ============================================================================
ALTER TABLE public.job_applications ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.job_applications
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.job_applications
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.job_applications
  ADD CONSTRAINT job_applications_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Authenticated users full access" ON public.job_applications;
CREATE POLICY "users_select_own" ON public.job_applications
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.job_applications
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.job_applications
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.job_applications
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_job_applications_user_id ON public.job_applications(user_id);

-- ============================================================================
-- 8. skills (48 rows) — scoped to user_id per Jason's decision 2026-04-19
-- ============================================================================
ALTER TABLE public.skills ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.skills
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.skills
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.skills
  ADD CONSTRAINT skills_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Allow all access to skills" ON public.skills;
CREATE POLICY "users_select_own" ON public.skills
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.skills
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.skills
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.skills
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_skills_user_id ON public.skills(user_id);

-- ============================================================================
-- 9. project_skills (40 rows) — had TWO permissive policies, drop both
-- ============================================================================
ALTER TABLE public.project_skills ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.project_skills
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.project_skills
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.project_skills
  ADD CONSTRAINT project_skills_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Allow all for anon" ON public.project_skills;
DROP POLICY IF EXISTS "Allow all for authenticated" ON public.project_skills;
CREATE POLICY "users_select_own" ON public.project_skills
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.project_skills
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.project_skills
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.project_skills
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_project_skills_user_id ON public.project_skills(user_id);

-- ============================================================================
-- 10. build_sessions (68 rows) — role was 'public' not 'authenticated'
-- ============================================================================
ALTER TABLE public.build_sessions ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.build_sessions
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.build_sessions
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.build_sessions
  ADD CONSTRAINT build_sessions_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
DROP POLICY IF EXISTS "Allow all for authenticated" ON public.build_sessions;
CREATE POLICY "users_select_own" ON public.build_sessions
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.build_sessions
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.build_sessions
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.build_sessions
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_build_sessions_user_id ON public.build_sessions(user_id);

-- ============================================================================
-- 11. profiles (1 row) — separate user_id column (keeps existing profiles.id FK intact)
-- ============================================================================
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS user_id uuid;
UPDATE public.profiles
  SET user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
  WHERE user_id IS NULL;
ALTER TABLE public.profiles
  ALTER COLUMN user_id SET NOT NULL,
  ALTER COLUMN user_id SET DEFAULT auth.uid();
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_user_id_unique UNIQUE (user_id);
DROP POLICY IF EXISTS "Authenticated users full access" ON public.profiles;
CREATE POLICY "users_select_own" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.profiles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.profiles
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.profiles
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON public.profiles(user_id);

-- =========================================================================
-- Verification: count rows with user_id set (should equal total row counts)
-- =========================================================================
-- Post-migration invariant: every row has user_id = Jason's auth.users.id.
-- Service-role policies remain in place; they still allow service_role full access.
;
