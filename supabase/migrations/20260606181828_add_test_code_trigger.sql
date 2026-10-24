-- Auto-generate test_code: {PROJECT_KEY}-TC-{SEQUENCE}
CREATE OR REPLACE FUNCTION generate_test_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_project_key TEXT;
  v_next_seq INTEGER;
  v_code TEXT;
BEGIN
  IF NEW.test_code IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT project_key INTO v_project_key
  FROM public.projects WHERE id = NEW.project_id;

  IF v_project_key IS NULL THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('testcase_' || v_project_key));

  SELECT COALESCE(MAX(
    CASE WHEN test_code ~ ('^' || v_project_key || '-TC-[0-9]+$')
    THEN CAST(SPLIT_PART(test_code, '-', array_length(string_to_array(test_code, '-'), 1)) AS INTEGER)
    ELSE 0 END
  ), 0) + 1 INTO v_next_seq
  FROM public.test_cases
  WHERE test_code LIKE v_project_key || '-TC-%';

  v_code := v_project_key || '-TC-' || LPAD(v_next_seq::TEXT, 3, '0');

  NEW.test_code := v_code;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_test_code
  BEFORE INSERT ON test_cases
  FOR EACH ROW
  EXECUTE FUNCTION generate_test_code();;
