
-- ============================================
-- CLAUDE MEMORY SYSTEM — Full Schema Migration
-- ============================================

-- 1. Enable pgvector for semantic search
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

-- 2. PROFILE TABLE — Core info about Jason
CREATE TABLE public.profile (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  email TEXT,
  bio TEXT,
  goals TEXT[],
  communication_style TEXT,
  work_preferences JSONB DEFAULT '{}',
  key_contacts JSONB DEFAULT '[]',
  tools_and_stack TEXT[],
  meta JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. PROJECTS TABLE — All projects tracked
CREATE TABLE public.projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'completed', 'archived')),
  priority TEXT DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high', 'critical')),
  tech_stack TEXT[],
  repo_urls TEXT[],
  links JSONB DEFAULT '[]',
  tags TEXT[],
  start_date DATE,
  end_date DATE,
  meta JSONB DEFAULT '{}',
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 4. DECISIONS TABLE — Key decisions linked to projects
CREATE TABLE public.decisions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  decision TEXT NOT NULL,
  reasoning TEXT,
  alternatives_considered TEXT[],
  tags TEXT[],
  meta JSONB DEFAULT '{}',
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 5. MEMORIES TABLE — Flexible catch-all memory entries
CREATE TABLE public.memories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL,
  type TEXT NOT NULL CHECK (type IN ('insight', 'preference', 'fact', 'lesson_learned', 'context', 'instruction')),
  content TEXT NOT NULL,
  summary TEXT,
  tags TEXT[],
  importance TEXT DEFAULT 'normal' CHECK (importance IN ('low', 'normal', 'high', 'critical')),
  embedding extensions.vector(1536),
  meta JSONB DEFAULT '{}',
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 6. CONVERSATIONS TABLE — Key takeaways from AI sessions
CREATE TABLE public.conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  key_decisions TEXT[],
  action_items TEXT[],
  topics TEXT[],
  tags TEXT[],
  source TEXT DEFAULT 'claude',
  meta JSONB DEFAULT '{}',
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 7. REFERENCES TABLE — Reusable snippets, templates, prompts
CREATE TABLE public.references (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID REFERENCES public.projects(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('snippet', 'template', 'prompt', 'document', 'link', 'note')),
  content TEXT NOT NULL,
  language TEXT,
  tags TEXT[],
  embedding extensions.vector(1536),
  meta JSONB DEFAULT '{}',
  archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================
-- INDEXES
-- ============================================

-- Fast lookups by project
CREATE INDEX idx_decisions_project ON public.decisions(project_id);
CREATE INDEX idx_memories_project ON public.memories(project_id);
CREATE INDEX idx_conversations_project ON public.conversations(project_id);
CREATE INDEX idx_references_project ON public.references(project_id);

-- Filter by type and status
CREATE INDEX idx_memories_type ON public.memories(type);
CREATE INDEX idx_projects_status ON public.projects(status);
CREATE INDEX idx_references_type ON public.references(type);

-- Filter out archived rows
CREATE INDEX idx_projects_archived ON public.projects(archived) WHERE archived = false;
CREATE INDEX idx_memories_archived ON public.memories(archived) WHERE archived = false;
CREATE INDEX idx_decisions_archived ON public.decisions(archived) WHERE archived = false;
CREATE INDEX idx_conversations_archived ON public.conversations(archived) WHERE archived = false;
CREATE INDEX idx_references_archived ON public.references(archived) WHERE archived = false;

-- GIN indexes for array tag searching
CREATE INDEX idx_projects_tags ON public.projects USING GIN(tags);
CREATE INDEX idx_memories_tags ON public.memories USING GIN(tags);
CREATE INDEX idx_decisions_tags ON public.decisions USING GIN(tags);
CREATE INDEX idx_conversations_tags ON public.conversations USING GIN(tags);
CREATE INDEX idx_references_tags ON public.references USING GIN(tags);

-- Vector similarity indexes (HNSW for fast approximate nearest neighbor)
CREATE INDEX idx_memories_embedding ON public.memories USING hnsw (embedding extensions.vector_cosine_ops);
CREATE INDEX idx_references_embedding ON public.references USING hnsw (embedding extensions.vector_cosine_ops);

-- ============================================
-- AUTO-UPDATE updated_at TRIGGER
-- ============================================

CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_profile_updated_at BEFORE UPDATE ON public.profile FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_projects_updated_at BEFORE UPDATE ON public.projects FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_decisions_updated_at BEFORE UPDATE ON public.decisions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_memories_updated_at BEFORE UPDATE ON public.memories FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_conversations_updated_at BEFORE UPDATE ON public.conversations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
CREATE TRIGGER trg_references_updated_at BEFORE UPDATE ON public.references FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================
-- ROW LEVEL SECURITY
-- ============================================

ALTER TABLE public.profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.memories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.references ENABLE ROW LEVEL SECURITY;

-- Allow service_role full access (this is what Claude uses via MCP)
CREATE POLICY "Service role full access" ON public.profile FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON public.projects FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON public.decisions FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON public.memories FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON public.conversations FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "Service role full access" ON public.references FOR ALL USING (true) WITH CHECK (true);
;
