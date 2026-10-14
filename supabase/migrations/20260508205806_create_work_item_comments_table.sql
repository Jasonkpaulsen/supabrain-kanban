
-- Step 5: Comments / activity log per work item
CREATE TABLE public.work_item_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id uuid NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  body text NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_wic_work_item ON public.work_item_comments(work_item_id);
CREATE INDEX idx_wic_user ON public.work_item_comments(user_id);

ALTER TABLE public.work_item_comments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_select_own" ON public.work_item_comments FOR SELECT
  USING (auth.uid() = user_id);
CREATE POLICY "users_insert_own" ON public.work_item_comments FOR INSERT
  WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_update_own" ON public.work_item_comments FOR UPDATE
  USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "users_delete_own" ON public.work_item_comments FOR DELETE
  USING (auth.uid() = user_id);
CREATE POLICY "service_role_full" ON public.work_item_comments FOR ALL USING (true) WITH CHECK (true);
;
