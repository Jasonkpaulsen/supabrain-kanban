
-- FAM-022 step 4: allow 'classroom_api' as a school_assignments.source (Classroom MCP ingestion).
ALTER TABLE public.school_assignments DROP CONSTRAINT school_assignments_source_check;
ALTER TABLE public.school_assignments
  ADD CONSTRAINT school_assignments_source_check
  CHECK (source = ANY (ARRAY['guardian_email'::text, 'playwright'::text, 'manual'::text, 'classroom_api'::text]));
-- ROLLBACK:
-- ALTER TABLE public.school_assignments DROP CONSTRAINT school_assignments_source_check;
-- ALTER TABLE public.school_assignments ADD CONSTRAINT school_assignments_source_check
--   CHECK (source = ANY (ARRAY['guardian_email'::text,'playwright'::text,'manual'::text]));
;
