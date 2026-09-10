CREATE TABLE school_assignments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  child_project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  child_name TEXT NOT NULL,
  class_name TEXT NOT NULL,
  teacher TEXT,
  title TEXT NOT NULL,
  description TEXT,
  assigned_date DATE,
  due_date DATE,
  status TEXT NOT NULL DEFAULT 'assigned' CHECK (status IN ('assigned', 'submitted', 'graded', 'missing', 'late', 'returned')),
  grade TEXT,
  max_grade TEXT,
  grade_numeric NUMERIC,
  source TEXT NOT NULL DEFAULT 'playwright' CHECK (source IN ('guardian_email', 'playwright', 'manual')),
  classroom_url TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  archived BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_school_assignments_child ON school_assignments (child_project_id);
CREATE INDEX idx_school_assignments_due ON school_assignments (due_date) WHERE archived = false;
CREATE INDEX idx_school_assignments_status ON school_assignments (status) WHERE status IN ('missing', 'late', 'assigned');
CREATE INDEX idx_school_assignments_child_class ON school_assignments (child_project_id, class_name);

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON school_assignments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE school_assignments ENABLE ROW LEVEL SECURITY;

CREATE POLICY service_role_full ON school_assignments FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON school_assignments FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = school_assignments.child_project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON school_assignments FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = school_assignments.child_project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON school_assignments FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = school_assignments.child_project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON school_assignments FOR DELETE TO authenticated
  USING ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE school_assignments IS 'Google Classroom assignments for Kai and Jai, scraped via Playwright or parsed from guardian emails. Shared with Mandy via project_members on child sub-projects.';;
