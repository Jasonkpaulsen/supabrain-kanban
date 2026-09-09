-- CLSRM-15 (2): the link is the whole point of the daily report — a parent can
-- only act on an assignment they can open. A scraper regression that stopped
-- setting classroom_url would currently be silent: rows would keep arriving,
-- the report would just quietly lose its links.
--
-- Scoped to source='playwright' rather than the whole table. The other allowed
-- sources (guardian_email, manual, classroom_api) have no scraped URL to give,
-- and a blanket NOT NULL would block them from ever being used. Verified 0 of
-- 14 current rows violate it before adding.
ALTER TABLE public.school_assignments
  DROP CONSTRAINT IF EXISTS school_assignments_scraped_rows_have_a_link;
ALTER TABLE public.school_assignments
  ADD CONSTRAINT school_assignments_scraped_rows_have_a_link
  CHECK (source <> 'playwright' OR classroom_url IS NOT NULL);

COMMENT ON CONSTRAINT school_assignments_scraped_rows_have_a_link
  ON public.school_assignments IS
  'CLSRM-15: a scraped row without its Classroom link fails loudly instead of silently dropping the link out of the daily report.';