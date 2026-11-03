
-- ============================================
-- Rename overlapping date columns for clarity
-- ============================================

-- date → discovered_date (when the listing was found/noted)
ALTER TABLE public.job_applications RENAME COLUMN "date" TO discovered_date;

-- timestamp → applied_at (when the application was submitted)
ALTER TABLE public.job_applications RENAME COLUMN "timestamp" TO applied_at;
;
