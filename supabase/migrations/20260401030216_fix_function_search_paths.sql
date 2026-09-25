
-- Fix mutable search_path on update_updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Fix mutable search_path on trigger_image_analysis
CREATE OR REPLACE FUNCTION public.trigger_image_analysis()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  project_url TEXT := 'https://hzqqvbvhnzmgqivfigej.supabase.co';
  payload JSONB;
  request_id BIGINT;
BEGIN
  IF NEW.bucket_id != 'project-assets' THEN
    RETURN NEW;
  END IF;

  IF NOT (
    NEW.name ILIKE '%.jpg' OR
    NEW.name ILIKE '%.jpeg' OR
    NEW.name ILIKE '%.png' OR
    NEW.name ILIKE '%.gif' OR
    NEW.name ILIKE '%.webp'
  ) THEN
    RETURN NEW;
  END IF;

  payload := jsonb_build_object(
    'storage_path', NEW.name,
    'bucket', NEW.bucket_id,
    'original_filename', split_part(NEW.name, '/', array_length(string_to_array(NEW.name, '/'), 1))
  );

  SELECT net.http_post(
    url := project_url || '/functions/v1/analyze-image',
    body := payload,
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) INTO request_id;

  RETURN NEW;
END;
$$;
;
