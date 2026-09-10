
-- Drop old trigger and function
DROP TRIGGER IF EXISTS trg_analyze_image_on_upload ON storage.objects;
DROP FUNCTION IF EXISTS public.trigger_image_analysis();

-- Recreate with correct pg_net function reference
CREATE OR REPLACE FUNCTION public.trigger_image_analysis()
RETURNS TRIGGER AS $$
DECLARE
  project_url TEXT := 'https://hzqqvbvhnzmgqivfigej.supabase.co';
  payload JSONB;
  request_id BIGINT;
BEGIN
  -- Only trigger for the project-assets bucket
  IF NEW.bucket_id != 'project-assets' THEN
    RETURN NEW;
  END IF;

  -- Only trigger for image files
  IF NOT (
    NEW.name ILIKE '%.jpg' OR
    NEW.name ILIKE '%.jpeg' OR
    NEW.name ILIKE '%.png' OR
    NEW.name ILIKE '%.gif' OR
    NEW.name ILIKE '%.webp'
  ) THEN
    RETURN NEW;
  END IF;

  -- Build the payload
  payload := jsonb_build_object(
    'storage_path', NEW.name,
    'bucket', NEW.bucket_id,
    'original_filename', split_part(NEW.name, '/', array_length(string_to_array(NEW.name, '/'), 1))
  );

  -- Call the Edge Function asynchronously via pg_net
  SELECT net.http_post(
    url := project_url || '/functions/v1/analyze-image',
    body := payload,
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) INTO request_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Reattach the trigger
CREATE TRIGGER trg_analyze_image_on_upload
  AFTER INSERT ON storage.objects
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_image_analysis();
;
