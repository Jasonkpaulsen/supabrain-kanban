
-- Revoke the default PUBLIC grant that all roles inherit
REVOKE EXECUTE ON FUNCTION public.get_dashboard_activity(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_schema_info() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_table_counts() FROM PUBLIC;

-- Re-grant only to authenticated users who need these
GRANT EXECUTE ON FUNCTION public.get_dashboard_activity(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_schema_info() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_table_counts() TO authenticated;

-- Also grant to service_role for admin use
GRANT EXECUTE ON FUNCTION public.get_dashboard_activity(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_schema_info() TO service_role;
GRANT EXECUTE ON FUNCTION public.get_table_counts() TO service_role;
;
