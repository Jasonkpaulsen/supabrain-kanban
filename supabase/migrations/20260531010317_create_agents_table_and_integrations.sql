
-- ============================================================
-- AGENTS TABLE — the orchestration layer between skills and projects
-- ============================================================
CREATE TABLE agents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id),
  
  -- Identity
  name          text NOT NULL,
  description   text,
  icon          text DEFAULT '🤖',
  
  -- Instructions & Behavior
  system_prompt text,                          -- core instructions / persona
  goals         text[],                        -- what this agent is trying to achieve
  constraints   text[],                        -- guardrails and boundaries
  
  -- Capabilities
  mcp_tools     text[],                        -- available MCP tools (e.g., 'mcp__supabase__execute_sql')
  model         text DEFAULT 'claude-sonnet-4-5', -- preferred model
  
  -- Automation & Triggers
  trigger_type  text DEFAULT 'manual'
    CHECK (trigger_type IN ('manual','scheduled','event','webhook')),
  trigger_config jsonb DEFAULT '{}'::jsonb,    -- cron expression, event conditions, webhook config
  auto_assign_rules jsonb DEFAULT '[]'::jsonb, -- rules for auto-assigning incoming tickets
  max_concurrent_tasks integer DEFAULT 5,      -- how many tasks agent can work simultaneously
  priority_rules jsonb DEFAULT '{}'::jsonb,    -- how agent prioritizes its queue
  escalation_rules jsonb DEFAULT '{}'::jsonb,  -- when to escalate to human
  
  -- Status & Observability
  status        text DEFAULT 'active'
    CHECK (status IN ('active','paused','disabled','archived')),
  last_run_at   timestamptz,
  run_count     integer DEFAULT 0,
  error_count   integer DEFAULT 0,
  last_error    text,
  avg_duration_ms integer,
  
  -- Classification
  tags          text[] DEFAULT '{}',
  meta          jsonb DEFAULT '{}'::jsonb,
  
  -- Timestamps
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

-- Index for common lookups
CREATE INDEX idx_agents_user_id ON agents(user_id);
CREATE INDEX idx_agents_status ON agents(status);
CREATE INDEX idx_agents_trigger_type ON agents(trigger_type);
CREATE INDEX idx_agents_tags ON agents USING GIN(tags);

-- RLS
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON agents
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON agents
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON agents
  FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON agents
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON agents
  FOR ALL TO service_role USING (true);

-- ============================================================
-- AGENT_SKILLS — which skills each agent can use
-- ============================================================
CREATE TABLE agent_skills (
  agent_id    uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  skill_id    uuid NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES auth.users(id),
  priority    integer DEFAULT 0,              -- skill priority within agent (higher = preferred)
  config      jsonb DEFAULT '{}'::jsonb,      -- per-agent skill configuration overrides
  assigned_at timestamptz DEFAULT now(),
  PRIMARY KEY (agent_id, skill_id)
);

CREATE INDEX idx_agent_skills_agent ON agent_skills(agent_id);
CREATE INDEX idx_agent_skills_skill ON agent_skills(skill_id);

ALTER TABLE agent_skills ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON agent_skills
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON agent_skills
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON agent_skills
  FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON agent_skills
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON agent_skills
  FOR ALL TO service_role USING (true);

-- ============================================================
-- AGENT_PROJECTS — which projects each agent operates on
-- ============================================================
CREATE TABLE agent_projects (
  agent_id    uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  project_id  uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES auth.users(id),
  role        text DEFAULT 'worker'
    CHECK (role IN ('worker','monitor','reviewer','owner')),
  scope       text DEFAULT 'all'
    CHECK (scope IN ('all','backlog','todo','in_progress','review','done')),
  assigned_at timestamptz DEFAULT now(),
  PRIMARY KEY (agent_id, project_id)
);

CREATE INDEX idx_agent_projects_agent ON agent_projects(agent_id);
CREATE INDEX idx_agent_projects_project ON agent_projects(project_id);

ALTER TABLE agent_projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON agent_projects
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON agent_projects
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON agent_projects
  FOR UPDATE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON agent_projects
  FOR DELETE TO authenticated USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON agent_projects
  FOR ALL TO service_role USING (true);

-- ============================================================
-- ADD AGENT ASSIGNMENT TO WORK_ITEMS
-- ============================================================
ALTER TABLE work_items 
  ADD COLUMN assigned_agent_id uuid REFERENCES agents(id) ON DELETE SET NULL;

CREATE INDEX idx_work_items_assigned_agent ON work_items(assigned_agent_id);

-- ============================================================
-- RECREATE KANBAN_BOARD_VIEW with agent info
-- ============================================================
DROP VIEW IF EXISTS kanban_board_view;

CREATE VIEW kanban_board_view AS
SELECT
  w.id,
  w.project_id,
  w.user_id,
  w.title,
  w.description,
  w.status,
  w.priority,
  w.sort_order,
  w.assignee,
  w.due_date,
  w.source_table,
  w.source_id,
  w.created_at,
  w.updated_at,
  w.completed_at,
  w.assigned_agent_id,
  p.name AS project_name,
  p.icon AS project_icon,
  a.name AS agent_name,
  a.icon AS agent_icon,
  a.status AS agent_status,
  COALESCE(
    (SELECT jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'color', l.color))
     FROM work_item_labels wl JOIN labels l ON l.id = wl.label_id
     WHERE wl.work_item_id = w.id),
    '[]'::jsonb
  ) AS labels,
  (SELECT count(*) FROM work_item_comments c WHERE c.work_item_id = w.id) AS comment_count
FROM work_items w
JOIN projects p ON p.id = w.project_id
LEFT JOIN agents a ON a.id = w.assigned_agent_id;

-- ============================================================
-- HELPER: Move work item with agent assignment support
-- ============================================================
CREATE OR REPLACE FUNCTION move_work_item(
  p_item_id uuid,
  p_new_status text,
  p_new_sort_order integer
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE work_items
  SET status = p_new_status,
      sort_order = p_new_sort_order,
      updated_at = now(),
      completed_at = CASE
        WHEN p_new_status = 'done' THEN COALESCE(completed_at, now())
        ELSE NULL
      END
  WHERE id = p_item_id;
END;
$$;

-- ============================================================
-- HELPER: Assign agent to work item
-- ============================================================
CREATE OR REPLACE FUNCTION assign_agent_to_item(
  p_item_id uuid,
  p_agent_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to modify this item';
  END IF;
  
  IF p_agent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM agents WHERE id = p_agent_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Agent not found or not authorized';
  END IF;

  UPDATE work_items
  SET assigned_agent_id = p_agent_id,
      updated_at = now()
  WHERE id = p_item_id;
END;
$$;
;
