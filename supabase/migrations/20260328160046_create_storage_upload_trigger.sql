
-- ============================================
-- AUTO-TRIGGER: Analyze images on upload
-- Uses pg_net to call the Edge Function
-- ============================================

CREATE OR REPLACE FUNCTION public.trigger_image_analysis()
RETURNS TRIGGER AS $$
DECLARE
  project_url TEXT := 'https://hzqqvbvhnzmgqivfigej.supabase.co';
  payload JSONB;
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
  PERFORM extensions.http_post(
    url := project_url || '/functions/v1/analyze-image',
    body := payload,
    headers := jsonb_build_object(
      'Content-Type', 'application/json'
    )
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach the trigger to storage.objects
CREATE TRIGGER trg_analyze_image_on_upload
  AFTER INSERT ON storage.objects
  FOR EACH ROW
  EXECUTE FUNCTION public.trigger_image_analysis();
;
