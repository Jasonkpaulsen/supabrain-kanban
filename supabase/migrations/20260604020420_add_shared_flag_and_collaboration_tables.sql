-- Add shared flag to projects
ALTER TABLE projects ADD COLUMN shared BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX idx_projects_shared ON projects (shared) WHERE shared = true;
COMMENT ON COLUMN projects.shared IS 'When true, this project uses the project_members table for multi-user access and the activity_log for agent collaboration. Non-shared projects skip these tables entirely.';

-- Project Members: who has access to shared projects
CREATE TABLE project_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('owner', 'editor', 'viewer')),
  invited_by UUID,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, user_id)
);

CREATE INDEX idx_project_members_project ON project_members (project_id);
CREATE INDEX idx_project_members_user ON project_members (user_id);

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON project_members
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE project_members ENABLE ROW LEVEL SECURITY;

-- Project members RLS: you can see memberships for projects you're a member of
CREATE POLICY service_role_full ON project_members FOR ALL TO service_role USING (true);
CREATE POLICY members_select ON project_members FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM project_members pm2 
    WHERE pm2.project_id = project_members.project_id 
    AND pm2.user_id = (SELECT auth.uid())
  ));
CREATE POLICY members_insert ON project_members FOR INSERT TO authenticated
  WITH CHECK (EXISTS (
    SELECT 1 FROM project_members pm2 
    WHERE pm2.project_id = project_members.project_id 
    AND pm2.user_id = (SELECT auth.uid()) 
    AND pm2.role = 'owner'
  ));
CREATE POLICY members_delete ON project_members FOR DELETE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM project_members pm2 
    WHERE pm2.project_id = project_members.project_id 
    AND pm2.user_id = (SELECT auth.uid()) 
    AND pm2.role = 'owner'
  ));

COMMENT ON TABLE project_members IS 'Multi-user access for shared projects. Only consulted when project.shared = true. Roles: owner (full + invite), editor (read/write), viewer (read-only).';

-- Activity Log: agent collaboration surface
CREATE TABLE activity_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id UUID NOT NULL,
  agent_name TEXT,
  action TEXT NOT NULL CHECK (action IN ('created', 'updated', 'archived', 'commented', 'moved', 'shared', 'unshared')),
  target_table TEXT NOT NULL,
  target_id UUID,
  summary TEXT NOT NULL,
  meta JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_activity_log_project ON activity_log (project_id);
CREATE INDEX idx_activity_log_user ON activity_log (user_id);
CREATE INDEX idx_activity_log_created ON activity_log (created_at DESC);
CREATE INDEX idx_activity_log_project_created ON activity_log (project_id, created_at DESC);

ALTER TABLE activity_log ENABLE ROW LEVEL SECURITY;

-- Activity log RLS: see activity for projects you're a member of
CREATE POLICY service_role_full ON activity_log FOR ALL TO service_role USING (true);
CREATE POLICY log_select ON activity_log FOR SELECT TO authenticated
  USING (
    user_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM project_members pm 
      WHERE pm.project_id = activity_log.project_id 
      AND pm.user_id = (SELECT auth.uid())
    )
  );
CREATE POLICY log_insert ON activity_log FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    OR EXISTS (
      SELECT 1 FROM project_members pm 
      WHERE pm.project_id = activity_log.project_id 
      AND pm.user_id = (SELECT auth.uid())
      AND pm.role IN ('owner', 'editor')
    )
  );

COMMENT ON TABLE activity_log IS 'Shared collaboration surface for agent-to-agent communication on shared projects. Every action by any user or agent on a shared project writes a log entry. Both owners and members can read the full activity stream.';;
