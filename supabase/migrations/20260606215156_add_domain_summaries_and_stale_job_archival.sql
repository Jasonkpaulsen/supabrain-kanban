-- SB-046: Add domain_summaries to jarvis_briefings
ALTER TABLE jarvis_briefings ADD COLUMN domain_summaries JSONB DEFAULT '{}'::jsonb;

COMMENT ON COLUMN jarvis_briefings.domain_summaries IS 'Per-domain narrative summaries. Keys: products, business, career, property, operations, family, hobbies, club. Values: 1-2 sentence summary per domain.';

-- SB-047: Add no_response status to job_applications
-- First drop old CHECK, add new one with no_response
ALTER TABLE job_applications DROP CONSTRAINT IF EXISTS job_applications_status_check;
ALTER TABLE job_applications ADD CONSTRAINT job_applications_status_check 
  CHECK (status = ANY(ARRAY['new', 'applied', 'interview', 'offer', 'accepted', 'rejected', 'withdrawn', 'skipped', 'no_response']));

-- Create archive function
CREATE OR REPLACE FUNCTION archive_stale_applications()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE public.job_applications SET 
    status = 'no_response', 
    updated_at = now()
  WHERE status = 'applied' 
    AND applied_at < NOW() - INTERVAL '30 days';
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

COMMENT ON FUNCTION archive_stale_applications IS 'Archives job applications that have been in applied status for 30+ days with no response. Called by JARVIS during daily delta. Pipeline Bookkeeper can resurrect by changing status on email match.';;
