-- SB-133: extend public.memories with agent attribution, scope, provenance, and value constraints.

-- 1. New columns
ALTER TABLE public.memories ADD COLUMN IF NOT EXISTS agent_id uuid REFERENCES public.agents(id) ON DELETE SET NULL;
ALTER TABLE public.memories ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'project';
ALTER TABLE public.memories ADD COLUMN IF NOT EXISTS source_table text;
ALTER TABLE public.memories ADD COLUMN IF NOT EXISTS source_id uuid;

-- 2. Normalize then constrain importance (defensive: coerce anything unexpected to 'normal')
UPDATE public.memories SET importance='normal' WHERE importance IS NULL OR importance NOT IN ('low','normal','high','critical');

-- 3. Value constraints (type values already conform to the taxonomy)
ALTER TABLE public.memories DROP CONSTRAINT IF EXISTS memories_scope_check;
ALTER TABLE public.memories ADD CONSTRAINT memories_scope_check CHECK (scope IN ('private','project','global'));
ALTER TABLE public.memories DROP CONSTRAINT IF EXISTS memories_type_check;
ALTER TABLE public.memories ADD CONSTRAINT memories_type_check CHECK (type IN ('fact','lesson_learned','context','instruction','insight','preference'));
ALTER TABLE public.memories DROP CONSTRAINT IF EXISTS memories_importance_check;
ALTER TABLE public.memories ADD CONSTRAINT memories_importance_check CHECK (importance IN ('low','normal','high','critical'));

-- 4. Backfill agent_id from meta (best-effort name match for the ~4 attributed rows)
UPDATE public.memories m SET agent_id = a.id
FROM public.agents a
WHERE m.agent_id IS NULL
  AND a.user_id = m.user_id
  AND a.name = COALESCE(m.meta->>'created_by', m.meta->>'agent', m.meta->>'created_by_agent');

-- 5. Indexes
CREATE INDEX IF NOT EXISTS idx_memories_agent ON public.memories(agent_id);
CREATE INDEX IF NOT EXISTS idx_memories_scope_project ON public.memories(scope, project_id);
CREATE INDEX IF NOT EXISTS idx_memories_source ON public.memories(source_table, source_id);

-- 6. Scope-aware SELECT policy (backward compatible: existing rows default to 'project')
DROP POLICY IF EXISTS users_select_own ON public.memories;
CREATE POLICY users_select_own ON public.memories FOR SELECT TO authenticated
USING (
  scope = 'global'
  OR user_id = (SELECT auth.uid())
  OR (scope = 'project' AND EXISTS (
        SELECT 1 FROM public.projects p
        JOIN public.project_members pm ON pm.project_id = p.id
        WHERE p.id = memories.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())))
);;
