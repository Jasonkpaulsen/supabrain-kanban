
-- Step 2: Create labels table
CREATE TABLE public.labels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  project_id uuid REFERENCES public.projects(id) ON DELETE CASCADE,
  name text NOT NULL,
  color text NOT NULL DEFAULT '#58a6ff',
  created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_labels_user_id ON public.labels(user_id);
CREATE INDEX idx_labels_project_id ON public.labels(project_id);

-- Unique label name per user per project scope
CREATE UNIQUE INDEX idx_labels_unique_name ON public.labels(user_id, COALESCE(project_id, '00000000-0000-0000-0000-000000000000'), name);

ALTER TABLE public.labels ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON public.labels FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.labels FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.labels FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.labels FOR DELETE USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON public.labels FOR ALL USING (true) WITH CHECK (true);

-- Seed default global labels
INSERT INTO public.labels (user_id, name, color) VALUES
  ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'Bug', '#f85149'),
  ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'Feature', '#58a6ff'),
  ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'Urgent', '#d29922'),
  ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'Research', '#8b5cf6'),
  ('5ecbd44a-a3e2-4363-9133-dff3851ba0f5', 'Blocked', '#8b949e');
;
