-- Enforce capability_match >= 0.60 hard floor on resume_generations
-- Prevents the pipeline from marking a resume as ready for submission
-- when capability_match is below the threshold, unless explicitly overridden.
-- Origin: JOB-028 Lenovo postmortem (capability_match 0.548 → rejected ATS)

CREATE OR REPLACE FUNCTION enforce_capability_match_floor()
RETURNS TRIGGER AS $$
DECLARE
  cap_match numeric;
  has_override boolean;
BEGIN
  -- Only check when validation_score has capability_match
  IF NEW.validation_score IS NOT NULL 
     AND NEW.validation_score ? 'capability_match' THEN
    
    cap_match := (NEW.validation_score->>'capability_match')::numeric;
    
    -- Check for explicit override flag
    has_override := COALESCE(
      (NEW.validation_score->>'hard_floor_override')::boolean, 
      false
    );
    
    -- If capability_match < 0.60 and no override, block non-rejection outcomes
    IF cap_match < 0.60 AND NOT has_override THEN
      -- Allow pending (initial state) and rejection/withdrawn outcomes
      -- Block: interview, offer (these mean the resume shipped past the gate)
      IF NEW.outcome IN ('interview', 'offer') THEN
        RAISE EXCEPTION 
          'HARD FLOOR VIOLATION: capability_match %.3f is below 0.60 minimum. '
          'Resume generation % cannot advance to outcome "%" without '
          'validation_score.hard_floor_override = true. '
          'Origin: JOB-028 postmortem rule.',
          cap_match, NEW.id, NEW.outcome;
      END IF;
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_capability_match_floor ON resume_generations;

CREATE TRIGGER trg_capability_match_floor
  BEFORE INSERT OR UPDATE ON resume_generations
  FOR EACH ROW
  EXECUTE FUNCTION enforce_capability_match_floor();;
