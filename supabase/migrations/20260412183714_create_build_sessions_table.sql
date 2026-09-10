
CREATE TABLE public.build_sessions (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  project_id UUID NOT NULL REFERENCES public.projects(id),
  session_number INTEGER NOT NULL,
  phase TEXT NOT NULL,
  sub_project TEXT NOT NULL,
  title TEXT NOT NULL,
  prompt TEXT NOT NULL,
  dependencies INTEGER[] DEFAULT '{}',
  expected_outputs TEXT[] DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'completed', 'blocked', 'skipped')),
  estimated_minutes INTEGER,
  actual_outputs TEXT[] DEFAULT '{}',
  session_notes TEXT,
  context_for_next TEXT,
  files_created TEXT[] DEFAULT '{}',
  files_modified TEXT[] DEFAULT '{}',
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, session_number)
);

ALTER TABLE public.build_sessions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Allow all for authenticated" ON public.build_sessions FOR ALL USING (true) WITH CHECK (true);

COMMENT ON TABLE public.build_sessions IS 'Session-by-session build plan for Way of the Turtle. Each record is one Cowork session with a copy-paste prompt, dependencies, expected outputs, and context bridging between sessions.';
COMMENT ON COLUMN public.build_sessions.prompt IS 'The exact prompt to paste into a new Cowork session. Includes full context so Claude can work without prior history.';
COMMENT ON COLUMN public.build_sessions.context_for_next IS 'Written by Claude at end of session — key decisions, gotchas, file locations, and state for the next session.';
COMMENT ON COLUMN public.build_sessions.dependencies IS 'Array of session_numbers that must be completed before this session can start.';
;
