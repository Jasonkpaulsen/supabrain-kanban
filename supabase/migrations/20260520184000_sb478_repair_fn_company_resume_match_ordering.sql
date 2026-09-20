-- SB-478: repair. fn_company_resume_match is created by the history fifteen days
-- after the first migration that needs it.
--
-- 20260520184031_pipeline_integrity_v2_dual_axis_v2 creates a view whose
-- definition calls fn_company_resume_match(). A view resolves its function
-- references at creation time, so the function must already exist -- and the
-- history does not create it until 20260604005354_fix_function_search_paths_batch2,
-- whose purpose was pinning search_path, not creating the function. In production
-- the function had been created out-of-band before 2026-05-20, so the view never
-- failed; on a fresh replay it has nothing to resolve against and the replay
-- stops at 51 of 266 (SB-439 cycle 4, 2026-09-20).
--
-- Placed at 20260520184000: strictly after 20260520183935 (the last migration
-- the replay applied) and strictly before 20260520184031 (the view). The
-- 20260604005354 CREATE OR REPLACE becomes a harmless no-op on replay.
--
-- Body rendered from the production catalog with pg_get_functiondef, not
-- transcribed. Production baseline: oid 33465, definition md5
-- b028be22e8a450d5da8219207fb837e4, 2228 chars. IMMUTABLE, not SECURITY
-- DEFINER, search_path pinned to the empty string, calls only built-ins --
-- nothing else has to move with it.
--
-- On production this row is recorded as applied without having run (the same
-- treatment SB-439's earlier repairs received under the decision "Option B --
-- supabase migration repair --status applied"). The function it would create is
-- byte-identical to the one already present, so the production end state is
-- unchanged by construction.
--
-- Distinct from SB-439's class: this object IS created by a migration, in the
-- wrong ORDER. TC-SB439-V1 (every object has a CREATE somewhere) passes and is
-- correct; this defect is invisible to it by design, as that case records.
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
