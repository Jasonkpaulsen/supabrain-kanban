-- Semantic search function for the skills catalog
-- Takes a query embedding and returns the closest matching skills
CREATE OR REPLACE FUNCTION public.match_skills(
  query_embedding vector(1536),
  match_threshold float DEFAULT 0.3,
  match_count int DEFAULT 5
)
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
  similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
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
    1 - (s.embedding <=> query_embedding) AS similarity
  FROM public.skills s
  WHERE s.archived = false
    AND s.embedding IS NOT NULL
    AND 1 - (s.embedding <=> query_embedding) > match_threshold
  ORDER BY s.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;;
