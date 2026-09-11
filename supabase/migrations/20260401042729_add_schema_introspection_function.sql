-- Function that returns full schema metadata for all public tables
-- The app calls this via supabase.rpc('get_schema_info') to dynamically build its UI

CREATE OR REPLACE FUNCTION public.get_schema_info()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result jsonb;
BEGIN
  SELECT jsonb_agg(t_info ORDER BY t_info->>'table_name')
  INTO result
  FROM (
    SELECT jsonb_build_object(
      'table_name', t.table_name,
      'columns', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'column_name', c.column_name,
            'data_type', c.data_type,
            'udt_name', c.udt_name,
            'is_nullable', c.is_nullable,
            'column_default', c.column_default,
            'ordinal_position', c.ordinal_position
          )
          ORDER BY c.ordinal_position
        )
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = t.table_name
      ),
      'check_constraints', (
        SELECT jsonb_agg(DISTINCT jsonb_build_object(
          'constraint_name', cc.constraint_name,
          'check_clause', cc.check_clause
        ))
        FROM information_schema.check_constraints cc
        JOIN information_schema.constraint_column_usage ccu
          ON cc.constraint_name = ccu.constraint_name
          AND cc.constraint_schema = ccu.constraint_schema
        WHERE ccu.table_schema = 'public'
          AND ccu.table_name = t.table_name
          AND cc.check_clause LIKE '%ANY%ARRAY%'
      ),
      'row_count', (
        SELECT reltuples::bigint
        FROM pg_class
        WHERE relname = t.table_name
        AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
      )
    ) AS t_info
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
  ) sub;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

-- Grant access to authenticated users
GRANT EXECUTE ON FUNCTION public.get_schema_info() TO authenticated;
;
