-- Junction table: many-to-many between projects and skills
CREATE TABLE public.project_skills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  skill_id text NOT NULL REFERENCES public.skills(skill_id) ON UPDATE CASCADE,
  assigned_by text DEFAULT 'manual',
  notes text,
  created_at timestamptz DEFAULT now(),

  -- Prevent duplicate assignments
  UNIQUE(project_id, skill_id)
);

-- Index for fast lookups in both directions
CREATE INDEX idx_project_skills_project ON public.project_skills(project_id);
CREATE INDEX idx_project_skills_skill ON public.project_skills(skill_id);

-- Enable RLS
ALTER TABLE public.project_skills ENABLE ROW LEVEL SECURITY;

-- Allow all operations for authenticated and anon (matches existing table policies)
CREATE POLICY "Allow all for anon" ON public.project_skills FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY "Allow all for authenticated" ON public.project_skills FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Function: get all skills for a project, including inherited from parent projects
CREATE OR REPLACE FUNCTION public.resolve_project_skills(target_project_id uuid)
RETURNS TABLE (
  skill_id text,
  name text,
  category text,
  description text,
  tags text[],
  rules text[],
  examples text[],
  dependencies text[],
  file_path text,
  source_path text,
  assigned_to_project_id uuid,
  assigned_to_project_name text,
  inherited boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  ancestor_ids uuid[];
BEGIN
  -- Collect the target project and all its ancestors
  WITH RECURSIVE ancestors AS (
    SELECT p.id, p.parent_project_id, p.name
    FROM public.projects p
    WHERE p.id = target_project_id
    
    UNION ALL
    
    SELECT p.id, p.parent_project_id, p.name
    FROM public.projects p
    INNER JOIN ancestors a ON p.id = a.parent_project_id
  )
  SELECT array_agg(a.id) INTO ancestor_ids FROM ancestors a;

  RETURN QUERY
  SELECT DISTINCT ON (s.skill_id)
    s.skill_id,
    s.name,
    s.category,
    s.description,
    s.tags,
    s.rules,
    s.examples,
    s.dependencies,
    s.file_path,
    s.source_path,
    ps.project_id AS assigned_to_project_id,
    proj.name AS assigned_to_project_name,
    (ps.project_id != target_project_id) AS inherited
  FROM public.project_skills ps
  INNER JOIN public.skills s ON s.skill_id = ps.skill_id AND s.archived = false
  INNER JOIN public.projects proj ON proj.id = ps.project_id
  WHERE ps.project_id = ANY(ancestor_ids)
  ORDER BY s.skill_id, inherited ASC;  -- prefer direct assignments over inherited
END;
$$;

-- Function: get all projects that use a given skill
CREATE OR REPLACE FUNCTION public.skill_projects(target_skill_id text)
RETURNS TABLE (
  project_id uuid,
  project_name text,
  project_status text,
  assigned_by text,
  notes text,
  assigned_at timestamptz
)
LANGUAGE sql
AS $$
  SELECT 
    p.id AS project_id,
    p.name AS project_name,
    p.status AS project_status,
    ps.assigned_by,
    ps.notes,
    ps.created_at AS assigned_at
  FROM public.project_skills ps
  INNER JOIN public.projects p ON p.id = ps.project_id AND p.archived = false
  WHERE ps.skill_id = target_skill_id
  ORDER BY p.name;
$$;;
