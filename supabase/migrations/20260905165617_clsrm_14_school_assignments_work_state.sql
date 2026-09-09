-- CLSRM-14: the child's own work state and attachments, from the "Your work"
-- panel on an assignment's /details page.
--
-- These are columns rather than meta keys because CLSRM-15's daily report has to
-- filter on them ("attached but not turned in", due within 24h).
--
-- One deviation from the tickets, recorded deliberately: CLSRM-13 asked for
-- meta.details_scraped_at and CLSRM-14 for a work_scraped_at column. Both mark
-- the same event — the single /details page load that feeds both parsers — so
-- storing it twice under two names would be the column-vs-meta duplication this
-- codebase keeps getting bitten by. One column, details_scraped_at, covers both.

ALTER TABLE public.school_assignments
  ADD COLUMN IF NOT EXISTS work_state text,
  ADD COLUMN IF NOT EXISTS attachment_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS attachments jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS details_scraped_at timestamptz;

-- 'draft_attached' is the state the whole ticket exists for: Classroom still
-- labels it "Assigned", but the panel lists files. A parent reading the report
-- needs to know the work is done and simply not handed in.
ALTER TABLE public.school_assignments
  DROP CONSTRAINT IF EXISTS school_assignments_work_state_check;
ALTER TABLE public.school_assignments
  ADD CONSTRAINT school_assignments_work_state_check
  CHECK (work_state IS NULL OR work_state IN
    ('assigned','draft_attached','turned_in','returned','missing'));

-- attachment_count must agree with the list it summarises, or the report can
-- say "2 attachments" while showing none.
ALTER TABLE public.school_assignments
  DROP CONSTRAINT IF EXISTS school_assignments_attachment_count_check;
ALTER TABLE public.school_assignments
  ADD CONSTRAINT school_assignments_attachment_count_check
  CHECK (attachment_count = jsonb_array_length(attachments));

COMMENT ON COLUMN public.school_assignments.work_state IS
  'CLSRM-14: richer than status — draft_attached means files are attached but nothing was turned in.';
COMMENT ON COLUMN public.school_assignments.attachments IS
  'CLSRM-14: [{name, kind: drive|link|upload|photo, url?}] scoped to the "Your work" panel only.';
COMMENT ON COLUMN public.school_assignments.details_scraped_at IS
  'CLSRM-13/14: when the /details page was last read. One column for both parsers — they share one page load.';