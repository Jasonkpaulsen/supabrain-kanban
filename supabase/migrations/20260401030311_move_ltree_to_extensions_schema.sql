
-- Drop dependent column first, move extension, recreate
ALTER TABLE public.projects DROP COLUMN path;
DROP EXTENSION ltree;
CREATE EXTENSION ltree SCHEMA extensions;
ALTER TABLE public.projects ADD COLUMN path extensions.ltree;
CREATE INDEX idx_projects_path ON public.projects USING gist (path);
;
