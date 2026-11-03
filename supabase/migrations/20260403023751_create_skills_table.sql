
-- Enable moddatetime extension
CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA extensions;

-- Dedicated skills table for the AI Skills catalog
CREATE TABLE public.skills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  skill_id text UNIQUE NOT NULL,
  name text NOT NULL,
  category text NOT NULL CHECK (category IN ('professional', 'technical', 'prompts', 'agents', 'templates')),
  description text NOT NULL,
  tags text[] DEFAULT '{}',
  rules text[] DEFAULT '{}',
  examples text[] DEFAULT '{}',
  dependencies text[] DEFAULT '{}',
  source text,
  source_path text,
  file_path text NOT NULL,
  vector_id text,
  embedding vector(1536),
  credentials text[] DEFAULT '{}',
  meta jsonb DEFAULT '{}'::jsonb,
  archived boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

-- Indexes
CREATE INDEX idx_skills_category ON public.skills (category);
CREATE INDEX idx_skills_tags ON public.skills USING GIN (tags);
CREATE INDEX idx_skills_embedding ON public.skills USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_skills_skill_id ON public.skills (skill_id);
CREATE INDEX idx_skills_archived ON public.skills (archived);

-- Auto-update updated_at trigger
CREATE TRIGGER set_skills_updated_at
  BEFORE UPDATE ON public.skills
  FOR EACH ROW
  EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- Enable RLS
ALTER TABLE public.skills ENABLE ROW LEVEL SECURITY;

-- Allow full access
CREATE POLICY "Allow all access to skills" ON public.skills
  FOR ALL USING (true) WITH CHECK (true);

COMMENT ON TABLE public.skills IS 'Centralized AI skill catalog — bidirectionally synced with file system at /AI/Skills/';
;
