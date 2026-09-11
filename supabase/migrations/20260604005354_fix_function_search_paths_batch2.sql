-- SEC-003: Fix mutable search_path on 5 functions
-- Using CREATE OR REPLACE to preserve grants and dependencies

CREATE OR REPLACE FUNCTION public.fn_pre_apply_check(p_job_app_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_row public.job_applications%ROWTYPE;
  v_gen_count int;
  v_violations text[] := ARRAY[]::text[];
BEGIN
  SELECT * INTO v_row FROM public.job_applications WHERE id = p_job_app_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'job_application not found', 'id', p_job_app_id);
  END IF;
  SELECT COUNT(*) INTO v_gen_count FROM public.resume_generations WHERE job_application_id = p_job_app_id;
  IF v_gen_count = 0 THEN
    v_violations := array_append(v_violations, 'R1: no resume_generations row — Stage 3 must run before applying');
  END IF;
  IF v_row.resume_file IS NULL THEN
    v_violations := array_append(v_violations, 'R2a: resume_file is NULL — log the file name being submitted');
  ELSIF NOT public.fn_company_resume_match(v_row.resume_file, v_row.company) THEN
    v_violations := array_append(v_violations,
      'R3: resume_file (' || v_row.resume_file || ') does not match target (' || v_row.company || ')');
  END IF;
  IF v_row.score IS NOT NULL AND v_row.score < 3.0 THEN
    v_violations := array_append(v_violations, 'R4: score ' || v_row.score::text || ' below v3 apply threshold (3.0)');
  END IF;
  IF v_row.decision IN ('MODERATE_MATCH','WEAK_MATCH','STRONG_MATCH','applied') THEN
    v_violations := array_append(v_violations,
      'R6: legacy label "' || v_row.decision || '" found in decision column (belongs in match_quality; decision should be apply/review/skip)');
  END IF;
  RETURN jsonb_build_object(
    'ok', cardinality(v_violations) = 0,
    'job_application_id', p_job_app_id,
    'company', v_row.company,
    'title', v_row.title,
    'match_quality', v_row.match_quality,
    'decision', v_row.decision,
    'violations', to_jsonb(v_violations),
    'checked_at', NOW()
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_company_resume_match(p_resume_file text, p_company text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO ''
AS $function$
DECLARE
  v_token text;
  v_clean text;
  v_aliases jsonb := jsonb_build_object(
    'Calvin Klein',          jsonb_build_array('CK'),
    'The Estée Lauder Companies', jsonb_build_array('ELC','EsteeLauder','Estee'),
    'Anheuser-Busch',        jsonb_build_array('AB','ABInBev'),
    'ZX Ventures',           jsonb_build_array('ABInBev','AB'),
    'Lancôme (L''Oréal)',    jsonb_build_array('Lancome','LOreal'),
    'The Connors Group',     jsonb_build_array('Connors','ConnorsGroup'),
    'MAC Cosmetics',         jsonb_build_array('MAC'),
    'Mammoth Brands',        jsonb_build_array('Harrys','Flamingo','Mando','Lume'),
    'JPMorganChase',         jsonb_build_array('JPM','JPMorgan','Chase'),
    'Deckers Brands',        jsonb_build_array('Deckers','UGG','HOKA','Teva'),
    'New York Blood Center Enterprises (NYBCe)', jsonb_build_array('NYBCe','NYBlood','BloodCenter'),
    'The Depository Trust & Clearing Corporation (DTCC)', jsonb_build_array('DTCC'),
    'Authentic Brands Group',jsonb_build_array('ABG'),
    'BAE Systems',           jsonb_build_array('BAE'),
    'Rag & Bone',            jsonb_build_array('RagBone','rag-bone')
  );
  v_alias_arr jsonb;
BEGIN
  IF p_resume_file IS NULL OR p_company IS NULL THEN RETURN false; END IF;
  IF p_resume_file ~* '(General|CIO_General|VP_PMO|General_2026|Test)' THEN RETURN true; END IF;
  v_alias_arr := v_aliases -> p_company;
  IF v_alias_arr IS NOT NULL THEN
    FOR v_token IN SELECT jsonb_array_elements_text(v_alias_arr) LOOP
      IF LOWER(p_resume_file) ~ LOWER(v_token) THEN RETURN true; END IF;
    END LOOP;
  END IF;
  v_clean := REGEXP_REPLACE(SPLIT_PART(p_company, ' (', 1), '[^A-Za-z ]', ' ', 'g');
  FOR v_token IN
    SELECT UNNEST(REGEXP_SPLIT_TO_ARRAY(LOWER(v_clean), '\s+'))
  LOOP
    IF length(v_token) >= 3
       AND v_token NOT IN ('the','inc','llc','ltd','group','company','companies','corp','corporation','co','and','for','com','app','dot')
       AND LOWER(p_resume_file) ~ v_token THEN
      RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.move_work_item(p_item_id uuid, p_new_status text, p_new_sort_order integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE public.work_items
  SET status = p_new_status,
      sort_order = p_new_sort_order,
      updated_at = now(),
      completed_at = CASE
        WHEN p_new_status = 'done' THEN COALESCE(completed_at, now())
        ELSE NULL
      END
  WHERE id = p_item_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.assign_agent_to_item(p_item_id uuid, p_agent_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.work_items WHERE id = p_item_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Not authorized to modify this item';
  END IF;
  
  IF p_agent_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.agents WHERE id = p_agent_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Agent not found or not authorized';
  END IF;

  UPDATE public.work_items
  SET assigned_agent_id = p_agent_id,
      updated_at = now()
  WHERE id = p_item_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_apply_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_check jsonb;
  v_violations jsonb;
BEGIN
  IF NEW.status = 'applied' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    IF COALESCE(NEW.notes,'') ILIKE '%[override-apply-guard]%' THEN
      RAISE NOTICE 'apply-guard bypassed for job_application % via override token in notes', NEW.id;
      RETURN NEW;
    END IF;
    v_check := public.fn_pre_apply_check(NEW.id);
    IF (v_check->>'ok')::boolean = false THEN
      v_violations := v_check->'violations';
      RAISE EXCEPTION 'Apply-guard blocked status→applied for %: violations = %. To override, append "[override-apply-guard]" to notes and retry.',
        NEW.id, v_violations;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;;
