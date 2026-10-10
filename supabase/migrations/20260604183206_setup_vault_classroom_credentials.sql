-- Enable pgsodium (required by Vault for encryption)
CREATE EXTENSION IF NOT EXISTS pgsodium;

-- Create the RPC function to retrieve classroom credentials securely
CREATE OR REPLACE FUNCTION public.get_classroom_credentials(child_name TEXT)
RETURNS TABLE(email TEXT, password TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  -- Only Jason can access these credentials
  IF auth.uid() != '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'::uuid THEN
    RAISE EXCEPTION 'Not authorized to access classroom credentials';
  END IF;

  IF lower(child_name) NOT IN ('kai', 'jai') THEN
    RAISE EXCEPTION 'Invalid child name. Use kai or jai.';
  END IF;

  RETURN QUERY
  SELECT 
    (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'classroom_' || lower(child_name) || '_email' LIMIT 1) AS email,
    (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'classroom_' || lower(child_name) || '_password' LIMIT 1) AS password;
END;
$function$;

-- Lock down access: only authenticated users (and specifically Jason via the function's internal check)
REVOKE EXECUTE ON FUNCTION public.get_classroom_credentials(TEXT) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_classroom_credentials(TEXT) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_classroom_credentials IS 'Retrieves Google Classroom credentials for Kai or Jai from Supabase Vault. Restricted to Jason only. Used by School Monitor agent for Playwright authentication.';;
