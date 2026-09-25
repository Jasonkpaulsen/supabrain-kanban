
-- Step 3: Create work_items table (core Kanban card)
CREATE TABLE public.work_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  description text,
  status text NOT NULL DEFAULT 'backlog' CHECK (status IN ('backlog', 'todo', 'in_progress', 'review', 'done')),
  priority text NOT NULL DEFAULT 'medium' CHECK (priority IN ('critical', 'high', 'medium', 'low')),
  sort_order integer NOT NULL DEFAULT 0,
  assignee text,
  due_date date,
  source_table text,
  source_id uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Indexes for fast board queries
CREATE INDEX idx_work_items_user_id ON public.work_items(user_id);
CREATE INDEX idx_work_items_project_id ON public.work_items(project_id);
CREATE INDEX idx_work_items_status ON public.work_items(status);
CREATE INDEX idx_work_items_priority ON public.work_items(priority);
CREATE INDEX idx_work_items_project_status ON public.work_items(project_id, status, sort_order);

ALTER TABLE public.work_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON public.work_items FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.work_items FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.work_items FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.work_items FOR DELETE USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON public.work_items FOR ALL USING (true) WITH CHECK (true);
;
