
-- Step 4: Junction table for many-to-many work_items <-> labels
CREATE TABLE public.work_item_labels (
  work_item_id uuid NOT NULL REFERENCES public.work_items(id) ON DELETE CASCADE,
  label_id uuid NOT NULL REFERENCES public.labels(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  PRIMARY KEY (work_item_id, label_id)
);

CREATE INDEX idx_wil_work_item ON public.work_item_labels(work_item_id);
CREATE INDEX idx_wil_label ON public.work_item_labels(label_id);

ALTER TABLE public.work_item_labels ENABLE ROW LEVEL SECURITY;

-- RLS: join through work_items to verify ownership
CREATE POLICY "users_select_own" ON public.work_item_labels FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_id AND wi.user_id = auth.uid()));
CREATE POLICY "users_insert_own" ON public.work_item_labels FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_id AND wi.user_id = auth.uid()));
CREATE POLICY "users_delete_own" ON public.work_item_labels FOR DELETE
  USING (EXISTS (SELECT 1 FROM public.work_items wi WHERE wi.id = work_item_id AND wi.user_id = auth.uid()));
CREATE POLICY "service_role_full" ON public.work_item_labels FOR ALL USING (true) WITH CHECK (true);
;
