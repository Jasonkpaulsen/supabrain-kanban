
-- 1. Add missing FK indexes
CREATE INDEX idx_job_applications_profile ON public.job_applications USING btree (profile_id);
CREATE INDEX idx_job_applications_project ON public.job_applications USING btree (project_id);

-- 2. Add CHECK constraint on status (includes existing values + common future ones)
ALTER TABLE public.job_applications
  ADD CONSTRAINT job_applications_status_check
  CHECK (status = ANY (ARRAY[
    'new'::text,
    'applied'::text,
    'form_incomplete'::text,
    'skipped'::text,
    'interviewing'::text,
    'offered'::text,
    'rejected'::text,
    'withdrawn'::text,
    'accepted'::text
  ]));

-- 3. Add missing updated_at trigger
CREATE TRIGGER trg_job_applications_updated_at
  BEFORE UPDATE ON public.job_applications
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at();

-- 4. Convert empty string defaults to NULL defaults
ALTER TABLE public.job_applications
  ALTER COLUMN url SET DEFAULT NULL,
  ALTER COLUMN source SET DEFAULT NULL,
  ALTER COLUMN decision SET DEFAULT NULL,
  ALTER COLUMN resume_file SET DEFAULT NULL,
  ALTER COLUMN reason SET DEFAULT NULL,
  ALTER COLUMN notes SET DEFAULT NULL;

-- 5. Convert existing empty strings to NULL for consistency
UPDATE public.job_applications SET url = NULL WHERE url = '';
UPDATE public.job_applications SET source = NULL WHERE source = '';
UPDATE public.job_applications SET decision = NULL WHERE decision = '';
UPDATE public.job_applications SET resume_file = NULL WHERE resume_file = '';
UPDATE public.job_applications SET reason = NULL WHERE reason = '';
UPDATE public.job_applications SET notes = NULL WHERE notes = '';
;
