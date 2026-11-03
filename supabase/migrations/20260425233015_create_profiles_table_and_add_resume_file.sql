
-- Candidate profile: contact, education, certifications, preferences
-- Single source of truth for resume header content
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  location TEXT,
  linkedin TEXT,
  website TEXT,
  bio TEXT,  -- 2-4 sentence positioning summary (template, gets tailored per role)
  education JSONB DEFAULT '[]',  -- [{degree, school, year, note}]
  certifications TEXT[] DEFAULT '{}',
  work_preferences JSONB DEFAULT '{}',  -- {remote_preference, geo, compensation_floor, industries}
  tools_and_stack TEXT[] DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_profiles_user ON profiles (user_id);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage own profile"
  ON profiles FOR ALL
  USING (auth.uid() = user_id OR user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5');

-- Add resume_file to job_applications if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'job_applications' AND column_name = 'resume_file'
  ) THEN
    ALTER TABLE job_applications ADD COLUMN resume_file TEXT;
  END IF;
END $$;
;
