
-- ============================================
-- IMAGE ASSETS TABLE — Auto-analyzed uploads
-- ============================================

CREATE TABLE public.image_assets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL,
  
  -- Storage info
  storage_path TEXT NOT NULL,
  storage_bucket TEXT NOT NULL DEFAULT 'project-assets',
  public_url TEXT,
  original_filename TEXT,
  file_size_bytes BIGINT,
  mime_type TEXT,
  
  -- Claude Vision analysis
  description TEXT,
  tags TEXT[],
  extracted_text TEXT,
  image_type TEXT CHECK (image_type IN ('screenshot', 'diagram', 'whiteboard', 'document', 'photo', 'receipt', 'business_card', 'other')),
  objects_detected TEXT[],
  
  -- Semantic search
  embedding extensions.vector(1536),
  
  -- Flexible metadata
  meta JSONB DEFAULT '{}',
  analysis_status TEXT NOT NULL DEFAULT 'pending' CHECK (analysis_status IN ('pending', 'processing', 'completed', 'failed')),
  analysis_error TEXT,
  
  -- Standard fields
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX idx_image_assets_project ON public.image_assets(project_id);
CREATE INDEX idx_image_assets_type ON public.image_assets(image_type);
CREATE INDEX idx_image_assets_status ON public.image_assets(analysis_status);
CREATE INDEX idx_image_assets_tags ON public.image_assets USING GIN(tags);
CREATE INDEX idx_image_assets_archived ON public.image_assets(archived) WHERE archived = false;
CREATE INDEX idx_image_assets_embedding ON public.image_assets USING hnsw (embedding extensions.vector_cosine_ops);

-- Auto-update timestamp trigger
CREATE TRIGGER trg_image_assets_updated_at BEFORE UPDATE ON public.image_assets FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- RLS
ALTER TABLE public.image_assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role full access" ON public.image_assets FOR ALL USING (true) WITH CHECK (true);

-- ============================================
-- STORAGE BUCKET
-- ============================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'project-assets',
  'project-assets',
  true,
  10485760,
  ARRAY['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml', 'application/pdf']
);

-- Allow public read access to the bucket
CREATE POLICY "Public read access" ON storage.objects FOR SELECT USING (bucket_id = 'project-assets');

-- Allow authenticated uploads
CREATE POLICY "Allow uploads" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'project-assets');

-- Allow updates and deletes
CREATE POLICY "Allow updates" ON storage.objects FOR UPDATE USING (bucket_id = 'project-assets');
CREATE POLICY "Allow deletes" ON storage.objects FOR DELETE USING (bucket_id = 'project-assets');
;
