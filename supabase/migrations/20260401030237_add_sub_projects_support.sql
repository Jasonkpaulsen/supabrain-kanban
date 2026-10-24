
-- Enable ltree extension for hierarchical queries
CREATE EXTENSION IF NOT EXISTS ltree SCHEMA public;

-- Add parent_project_id for sub-project hierarchy
ALTER TABLE public.projects
  ADD COLUMN parent_project_id UUID REFERENCES public.projects(id) ON DELETE CASCADE;

-- Add materialized path for efficient tree queries
ALTER TABLE public.projects
  ADD COLUMN path public.ltree;

-- Index for parent lookups
CREATE INDEX idx_projects_parent ON public.projects USING btree (parent_project_id);

-- GiST index for ltree path queries (ancestors, descendants)
CREATE INDEX idx_projects_path ON public.projects USING gist (path);

-- Add depth column for easy level filtering
ALTER TABLE public.projects
  ADD COLUMN depth INTEGER DEFAULT 0;
;
