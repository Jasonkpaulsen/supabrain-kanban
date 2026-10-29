CREATE OR REPLACE FUNCTION public.trigger_memory_embedding()
RETURNS trigger LANGUAGE plpgsql SET search_path TO '' AS $$
DECLARE
  project_url text := 'https://hzqqvbvhnzmgqivfigej.supabase.co';
  request_id bigint;
BEGIN
  SELECT net.http_post(
    url := project_url || '/functions/v1/generate-memory-embeddings',
    body := jsonb_build_object('memory_id', NEW.id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  ) INTO request_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_memory_embed ON public.memories;
CREATE TRIGGER trg_memory_embed
AFTER INSERT OR UPDATE OF content, summary, type, tags ON public.memories
FOR EACH ROW EXECUTE FUNCTION public.trigger_memory_embedding();

CREATE INDEX IF NOT EXISTS idx_memories_embedding_hnsw
  ON public.memories USING hnsw (embedding extensions.vector_cosine_ops);

CREATE OR REPLACE FUNCTION public.match_memories(
  query_embedding extensions.vector,
  match_count int DEFAULT 10,
  p_project uuid DEFAULT NULL,
  p_agent uuid DEFAULT NULL,
  p_scope text[] DEFAULT NULL,
  p_type text[] DEFAULT NULL,
  p_min_importance text DEFAULT NULL
)
RETURNS TABLE(id uuid, type text, summary text, content text, importance text, scope text, agent_id uuid, project_id uuid, similarity double precision)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO ''
AS $$
  SELECT m.id, m.type, m.summary, m.content, m.importance, m.scope, m.agent_id, m.project_id,
         1 - (m.embedding OPERATOR(extensions.<=>) query_embedding) AS similarity
  FROM public.memories m
  WHERE m.embedding IS NOT NULL
    AND m.archived = false
    AND (p_project IS NULL OR m.project_id = p_project)
    AND (p_agent IS NULL OR m.agent_id = p_agent)
    AND (p_scope IS NULL OR m.scope = ANY(p_scope))
    AND (p_type IS NULL OR m.type = ANY(p_type))
    AND (p_min_importance IS NULL OR
         array_position(ARRAY['low','normal','high','critical'], m.importance)
         >= array_position(ARRAY['low','normal','high','critical'], p_min_importance))
  ORDER BY m.embedding OPERATOR(extensions.<=>) query_embedding
  LIMIT match_count;
$$;

REVOKE EXECUTE ON FUNCTION public.match_memories FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.match_memories TO authenticated, service_role;;
