-- SEC-008 / SB-127: restrict vault-reading SECURITY DEFINER function to backend (service_role) only.
-- Function already has SET search_path='' and an internal auth.uid() owner check; this removes
-- the authenticated/PUBLIC EXECUTE grant flagged by advisor lint 0029. Reversible via re-GRANT.
REVOKE EXECUTE ON FUNCTION public.get_classroom_credentials(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_classroom_credentials(text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.get_classroom_credentials(text) TO service_role;;
