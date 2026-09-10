
-- Revoke with correct signatures
REVOKE EXECUTE ON FUNCTION public.get_dashboard_activity(item_limit integer) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_schema_info() FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_table_counts() FROM anon;

-- Also revoke default privileges on public schema functions for anon
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- Re-grant execute on non-sensitive functions if any exist
-- (none needed — all public functions in OpenBrain are admin/dashboard functions)
;
