-- Update RLS on core content tables to allow access via project_members on shared projects
-- Pattern: owner access OR (project is shared AND user is a member with appropriate role)

-- MEMORIES
DROP POLICY IF EXISTS users_select_own ON memories;
DROP POLICY IF EXISTS users_insert_own ON memories;
DROP POLICY IF EXISTS users_update_own ON memories;
DROP POLICY IF EXISTS users_delete_own ON memories;

CREATE POLICY users_select_own ON memories FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = memories.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON memories FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = memories.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON memories FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = memories.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON memories FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

-- DECISIONS
DROP POLICY IF EXISTS users_select_own ON decisions;
DROP POLICY IF EXISTS users_insert_own ON decisions;
DROP POLICY IF EXISTS users_update_own ON decisions;
DROP POLICY IF EXISTS users_delete_own ON decisions;

CREATE POLICY users_select_own ON decisions FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = decisions.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON decisions FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = decisions.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON decisions FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = decisions.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON decisions FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

-- REFERENCE_ITEMS
DROP POLICY IF EXISTS users_select_own ON reference_items;
DROP POLICY IF EXISTS users_insert_own ON reference_items;
DROP POLICY IF EXISTS users_update_own ON reference_items;
DROP POLICY IF EXISTS users_delete_own ON reference_items;

CREATE POLICY users_select_own ON reference_items FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = reference_items.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON reference_items FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = reference_items.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON reference_items FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = reference_items.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON reference_items FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

-- CONVERSATIONS
DROP POLICY IF EXISTS users_select_own ON conversations;
DROP POLICY IF EXISTS users_insert_own ON conversations;
DROP POLICY IF EXISTS users_update_own ON conversations;
DROP POLICY IF EXISTS users_delete_own ON conversations;

CREATE POLICY users_select_own ON conversations FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = conversations.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON conversations FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = conversations.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON conversations FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = conversations.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON conversations FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

-- PROJECTS: members can see shared projects they belong to
DROP POLICY IF EXISTS users_select_own ON projects;
DROP POLICY IF EXISTS users_insert_own ON projects;
DROP POLICY IF EXISTS users_update_own ON projects;
DROP POLICY IF EXISTS users_delete_own ON projects;

CREATE POLICY users_select_own ON projects FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR (shared = true AND EXISTS (
    SELECT 1 FROM project_members pm WHERE pm.project_id = projects.id AND pm.user_id = (SELECT auth.uid())
  )));
CREATE POLICY users_insert_own ON projects FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY users_update_own ON projects FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id);
CREATE POLICY users_delete_own ON projects FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);;
