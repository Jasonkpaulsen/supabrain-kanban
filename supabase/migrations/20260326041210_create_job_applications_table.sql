
CREATE TABLE job_applications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID REFERENCES profile(id),
  project_id UUID REFERENCES projects(id),
  date DATE NOT NULL,
  timestamp TIMESTAMPTZ,
  company TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT DEFAULT '',
  source TEXT DEFAULT '',
  score NUMERIC(4,2) DEFAULT 0.0,
  decision TEXT DEFAULT '',
  status TEXT DEFAULT 'new',
  resume_file TEXT DEFAULT '',
  reason TEXT DEFAULT '',
  notes TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Add RLS
ALTER TABLE job_applications ENABLE ROW LEVEL SECURITY;

-- Allow all operations for authenticated users
CREATE POLICY "Allow all for authenticated users" ON job_applications
  FOR ALL USING (true) WITH CHECK (true);

-- Index for common queries
CREATE INDEX idx_job_applications_status ON job_applications(status);
CREATE INDEX idx_job_applications_score ON job_applications(score DESC);
CREATE INDEX idx_job_applications_company ON job_applications(company);
;
