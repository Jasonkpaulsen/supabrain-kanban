-- MASTER RLS POLICY REWRITE
-- Covers: SEC-001 (WITH CHECK), SEC-004 (public→authenticated + remove hardcoded UUID),
--         SEC-005 (profiles dedup), OPT-004 (auth.uid() caching)
-- 
-- Pattern for all standard tables:
--   SELECT: USING ((SELECT auth.uid()) = user_id) TO authenticated
--   INSERT: WITH CHECK ((SELECT auth.uid()) = user_id) TO authenticated
--   UPDATE: USING ((SELECT auth.uid()) = user_id) TO authenticated
--   DELETE: USING ((SELECT auth.uid()) = user_id) TO authenticated

-- ============================================================
-- GROUP 1: Standard tables already on authenticated (fix INSERT + cache)
-- ============================================================

-- agent_projects
DROP POLICY IF EXISTS users_select_own ON agent_projects;
DROP POLICY IF EXISTS users_insert_own ON agent_projects;
DROP POLICY IF EXISTS users_update_own ON agent_projects;
DROP POLICY IF EXISTS users_delete_own ON agent_projects;
CREATE POLICY users_select_own ON agent_projects FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON agent_projects FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON agent_projects FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON agent_projects FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- agent_skills
DROP POLICY IF EXISTS users_select_own ON agent_skills;
DROP POLICY IF EXISTS users_insert_own ON agent_skills;
DROP POLICY IF EXISTS users_update_own ON agent_skills;
DROP POLICY IF EXISTS users_delete_own ON agent_skills;
CREATE POLICY users_select_own ON agent_skills FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON agent_skills FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON agent_skills FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON agent_skills FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- agents
DROP POLICY IF EXISTS users_select_own ON agents;
DROP POLICY IF EXISTS users_insert_own ON agents;
DROP POLICY IF EXISTS users_update_own ON agents;
DROP POLICY IF EXISTS users_delete_own ON agents;
CREATE POLICY users_select_own ON agents FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON agents FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON agents FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON agents FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- build_sessions
DROP POLICY IF EXISTS users_select_own ON build_sessions;
DROP POLICY IF EXISTS users_insert_own ON build_sessions;
DROP POLICY IF EXISTS users_update_own ON build_sessions;
DROP POLICY IF EXISTS users_delete_own ON build_sessions;
CREATE POLICY users_select_own ON build_sessions FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON build_sessions FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON build_sessions FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON build_sessions FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- conversations
DROP POLICY IF EXISTS users_select_own ON conversations;
DROP POLICY IF EXISTS users_insert_own ON conversations;
DROP POLICY IF EXISTS users_update_own ON conversations;
DROP POLICY IF EXISTS users_delete_own ON conversations;
CREATE POLICY users_select_own ON conversations FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON conversations FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON conversations FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON conversations FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- decisions
DROP POLICY IF EXISTS users_select_own ON decisions;
DROP POLICY IF EXISTS users_insert_own ON decisions;
DROP POLICY IF EXISTS users_update_own ON decisions;
DROP POLICY IF EXISTS users_delete_own ON decisions;
CREATE POLICY users_select_own ON decisions FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON decisions FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON decisions FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON decisions FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- employer_details
DROP POLICY IF EXISTS auth_select_employer_details ON employer_details;
DROP POLICY IF EXISTS auth_insert_employer_details ON employer_details;
DROP POLICY IF EXISTS auth_update_employer_details ON employer_details;
DROP POLICY IF EXISTS auth_delete_employer_details ON employer_details;
CREATE POLICY users_select_own ON employer_details FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON employer_details FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON employer_details FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON employer_details FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- image_assets
DROP POLICY IF EXISTS users_select_own ON image_assets;
DROP POLICY IF EXISTS users_insert_own ON image_assets;
DROP POLICY IF EXISTS users_update_own ON image_assets;
DROP POLICY IF EXISTS users_delete_own ON image_assets;
CREATE POLICY users_select_own ON image_assets FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON image_assets FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON image_assets FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON image_assets FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- job_applications
DROP POLICY IF EXISTS users_select_own ON job_applications;
DROP POLICY IF EXISTS users_insert_own ON job_applications;
DROP POLICY IF EXISTS users_update_own ON job_applications;
DROP POLICY IF EXISTS users_delete_own ON job_applications;
CREATE POLICY users_select_own ON job_applications FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON job_applications FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON job_applications FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON job_applications FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- memories
DROP POLICY IF EXISTS users_select_own ON memories;
DROP POLICY IF EXISTS users_insert_own ON memories;
DROP POLICY IF EXISTS users_update_own ON memories;
DROP POLICY IF EXISTS users_delete_own ON memories;
CREATE POLICY users_select_own ON memories FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON memories FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON memories FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON memories FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- project_skills
DROP POLICY IF EXISTS users_select_own ON project_skills;
DROP POLICY IF EXISTS users_insert_own ON project_skills;
DROP POLICY IF EXISTS users_update_own ON project_skills;
DROP POLICY IF EXISTS users_delete_own ON project_skills;
CREATE POLICY users_select_own ON project_skills FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON project_skills FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON project_skills FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON project_skills FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- projects
DROP POLICY IF EXISTS users_select_own ON projects;
DROP POLICY IF EXISTS users_insert_own ON projects;
DROP POLICY IF EXISTS users_update_own ON projects;
DROP POLICY IF EXISTS users_delete_own ON projects;
CREATE POLICY users_select_own ON projects FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON projects FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON projects FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON projects FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- reference_items
DROP POLICY IF EXISTS users_select_own ON reference_items;
DROP POLICY IF EXISTS users_insert_own ON reference_items;
DROP POLICY IF EXISTS users_update_own ON reference_items;
DROP POLICY IF EXISTS users_delete_own ON reference_items;
CREATE POLICY users_select_own ON reference_items FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON reference_items FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON reference_items FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON reference_items FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- skills
DROP POLICY IF EXISTS users_select_own ON skills;
DROP POLICY IF EXISTS users_insert_own ON skills;
DROP POLICY IF EXISTS users_update_own ON skills;
DROP POLICY IF EXISTS users_delete_own ON skills;
CREATE POLICY users_select_own ON skills FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON skills FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON skills FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON skills FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- ============================================================
-- GROUP 2: Tables on public role → switch to authenticated (SEC-004)
-- ============================================================

-- labels
DROP POLICY IF EXISTS users_select_own ON labels;
DROP POLICY IF EXISTS users_insert_own ON labels;
DROP POLICY IF EXISTS users_update_own ON labels;
DROP POLICY IF EXISTS users_delete_own ON labels;
CREATE POLICY users_select_own ON labels FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON labels FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON labels FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON labels FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- work_items
DROP POLICY IF EXISTS users_select_own ON work_items;
DROP POLICY IF EXISTS users_insert_own ON work_items;
DROP POLICY IF EXISTS users_update_own ON work_items;
DROP POLICY IF EXISTS users_delete_own ON work_items;
CREATE POLICY users_select_own ON work_items FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON work_items FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON work_items FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON work_items FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- work_item_comments
DROP POLICY IF EXISTS users_select_own ON work_item_comments;
DROP POLICY IF EXISTS users_insert_own ON work_item_comments;
DROP POLICY IF EXISTS users_update_own ON work_item_comments;
DROP POLICY IF EXISTS users_delete_own ON work_item_comments;
CREATE POLICY users_select_own ON work_item_comments FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON work_item_comments FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON work_item_comments FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON work_item_comments FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- ============================================================
-- GROUP 3: Junction table with EXISTS (SEC-004 public→authenticated)
-- ============================================================

-- work_item_labels
DROP POLICY IF EXISTS users_select_own ON work_item_labels;
DROP POLICY IF EXISTS users_insert_own ON work_item_labels;
DROP POLICY IF EXISTS users_delete_own ON work_item_labels;
CREATE POLICY users_select_own ON work_item_labels FOR SELECT TO authenticated 
  USING (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_labels.work_item_id AND wi.user_id = (SELECT auth.uid())));
CREATE POLICY users_insert_own ON work_item_labels FOR INSERT TO authenticated 
  WITH CHECK (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_labels.work_item_id AND wi.user_id = (SELECT auth.uid())));
CREATE POLICY users_delete_own ON work_item_labels FOR DELETE TO authenticated 
  USING (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_labels.work_item_id AND wi.user_id = (SELECT auth.uid())));

-- ============================================================
-- GROUP 4: Tables with hardcoded UUID → proper CRUD (SEC-004)
-- ============================================================

-- career_experiences
DROP POLICY IF EXISTS "Users can manage their own career experiences" ON career_experiences;
CREATE POLICY users_select_own ON career_experiences FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON career_experiences FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON career_experiences FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON career_experiences FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- career_interview_questions
DROP POLICY IF EXISTS "Users manage their own interview questions" ON career_interview_questions;
CREATE POLICY users_select_own ON career_interview_questions FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON career_interview_questions FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON career_interview_questions FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON career_interview_questions FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- resume_generations
DROP POLICY IF EXISTS "Users can manage their own resume generations" ON resume_generations;
CREATE POLICY users_select_own ON resume_generations FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON resume_generations FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON resume_generations FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON resume_generations FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- ============================================================
-- GROUP 5: profiles — drop duplicate ALL policy (SEC-005)
-- ============================================================

DROP POLICY IF EXISTS "Users manage own profile" ON profiles;
DROP POLICY IF EXISTS users_select_own ON profiles;
DROP POLICY IF EXISTS users_insert_own ON profiles;
DROP POLICY IF EXISTS users_update_own ON profiles;
DROP POLICY IF EXISTS users_delete_own ON profiles;
CREATE POLICY users_select_own ON profiles FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_insert_own ON profiles FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON profiles FOR UPDATE TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON profiles FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);;
