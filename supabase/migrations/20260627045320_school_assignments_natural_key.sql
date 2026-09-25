-- BA-16: stable natural key for idempotent upserts from the Classroom scraper.
-- coursework_id is the Google Classroom courseWork id (the <aid> in the URL),
-- unique within a child's account. Table is empty, so this is zero-risk.
ALTER TABLE public.school_assignments
  ADD COLUMN IF NOT EXISTS coursework_id text;

CREATE UNIQUE INDEX IF NOT EXISTS school_assignments_natural_key
  ON public.school_assignments (child_project_id, source, coursework_id);

COMMENT ON COLUMN public.school_assignments.coursework_id IS
  'Google Classroom courseWork id (stable scrape key). Natural upsert key with (child_project_id, source).';;
