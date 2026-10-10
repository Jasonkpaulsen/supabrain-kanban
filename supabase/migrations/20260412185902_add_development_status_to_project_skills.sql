ALTER TABLE public.project_skills 
ADD COLUMN IF NOT EXISTS development_status TEXT NOT NULL DEFAULT 'not_started' 
CHECK (development_status IN ('not_started', 'in_progress', 'developed', 'existing')),
ADD COLUMN IF NOT EXISTS tier TEXT CHECK (tier IN ('critical', 'important', 'polish')),
ADD COLUMN IF NOT EXISTS sessions_used INTEGER[] DEFAULT '{}',
ADD COLUMN IF NOT EXISTS proficiency_level TEXT CHECK (proficiency_level IN ('none', 'beginner', 'intermediate', 'advanced', 'expert'));;
