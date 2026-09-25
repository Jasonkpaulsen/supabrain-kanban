
-- Revoke anonymous execution on SECURITY DEFINER functions
REVOKE EXECUTE ON FUNCTION public.get_dashboard_activity FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_schema_info FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_table_counts FROM anon;
;
