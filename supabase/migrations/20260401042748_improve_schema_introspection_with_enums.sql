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
        SELECT jsonb_agg(jsonb_build_object(
          'column_name', a.attname,
          'allowed_values', (
            SELECT jsonb_agg(val ORDER BY val)
            FROM (
              SELECT unnest(
                regexp_matches(
                  pg_get_constraintdef(con.oid),
                  '''([^'']+)''',
                  'g'
                )
              ) AS val
            ) extracted
          )
        ))
        FROM pg_constraint con
        JOIN pg_attribute a ON a.attnum = ANY(con.conkey)
          AND a.attrelid = con.conrelid
        WHERE con.conrelid = (
          SELECT oid FROM pg_class
          WHERE relname = t.table_name
          AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
        )
        AND con.contype = 'c'
        AND pg_get_constraintdef(con.oid) LIKE '%ANY%ARRAY%'
      )
    ) AS t_info
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
  ) sub;

  RETURN COALESCE(result, '[]'::jsonb);
END;
$$;
;
