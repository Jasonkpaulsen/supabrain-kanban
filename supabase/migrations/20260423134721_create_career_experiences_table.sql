
-- Career experiences: comprehensive record of every professional initiative, project, and achievement
-- Designed to be queried by capability theme, scale, technology, and industry for resume generation

CREATE TABLE career_experiences (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  
  -- Context: where and when
  employer TEXT NOT NULL,
  role_title TEXT NOT NULL,
  start_date DATE,
  end_date DATE,
  location TEXT,
  
  -- The experience itself
  initiative_title TEXT NOT NULL,  -- e.g. "iPad Retail Rollout Program"
  description TEXT NOT NULL,       -- full narrative of what was done
  
  -- Scale & impact metrics
  scale_metrics JSONB DEFAULT '{}',  -- {"people_impacted": 5000, "locations": 1100, "budget": 5500000, "team_size": 60}
  outcomes TEXT[],                    -- measurable results: ["3% revenue lift", "6 AI pilots launched in 8 months"]
  
  -- Categorization for matching
  capability_tags TEXT[] NOT NULL DEFAULT '{}',  -- transferable skills: ["field_deployment", "change_management", "hardware_provisioning"]
  technologies TEXT[] DEFAULT '{}',               -- specific tech: ["SAP Commerce Cloud", "Salesforce", "iPads", "Ping SSO"]
  industry_context TEXT[] DEFAULT '{}',           -- ["luxury", "beauty", "retail", "b2b", "b2c", "consulting"]
  
  -- Resume generation helpers
  resume_bullet_variants JSONB DEFAULT '[]',  -- pre-written bullet variations for different framings
  transferable_themes TEXT[] DEFAULT '{}',     -- high-level themes: ["digital_transformation", "deployment_adoption", "ai_enablement", "platform_modernization"]
  seniority_level TEXT CHECK (seniority_level IN ('ic', 'manager', 'director', 'vp', 'svp', 'c_level')),
  
  -- Source tracking
  source_resumes TEXT[] DEFAULT '{}',  -- which resume files this was extracted from
  verified_by_user BOOLEAN DEFAULT FALSE,  -- has Jason confirmed/enriched this record
  
  -- Metadata
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index for capability-based querying (the core resume matching operation)
CREATE INDEX idx_career_exp_capabilities ON career_experiences USING GIN (capability_tags);
CREATE INDEX idx_career_exp_themes ON career_experiences USING GIN (transferable_themes);
CREATE INDEX idx_career_exp_technologies ON career_experiences USING GIN (technologies);
CREATE INDEX idx_career_exp_industry ON career_experiences USING GIN (industry_context);
CREATE INDEX idx_career_exp_user ON career_experiences (user_id);

-- Resume generation history: tracks what was produced and how it performed
CREATE TABLE resume_generations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  job_application_id UUID REFERENCES job_applications(id),
  
  -- Job analysis
  job_title TEXT NOT NULL,
  company TEXT NOT NULL,
  job_posting_url TEXT,
  job_requirements JSONB DEFAULT '{}',  -- parsed requirements from posting
  
  -- Generation details
  experiences_selected UUID[] DEFAULT '{}',  -- which career_experiences were used
  resume_file_path TEXT,
  cover_letter_file_path TEXT,
  
  -- Pre-submission validation
  validation_score JSONB DEFAULT '{}',  -- {"basic_quals_met": true, "ats_keyword_score": 85, "industry_match": 0.6, "gaps": ["no services industry exp"]}
  gaps_identified TEXT[] DEFAULT '{}',
  
  -- Post-submission outcome
  outcome TEXT CHECK (outcome IN ('pending', 'rejected_ats', 'rejected_recruiter', 'rejected_interview', 'interview', 'offer', 'ghosted', 'withdrawn')),
  outcome_notes TEXT,
  rejection_reason TEXT,  -- capture specifics like "did not meet basic qualifications"
  
  -- Learning
  lessons_learned TEXT,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_resume_gen_user ON resume_generations (user_id);
CREATE INDEX idx_resume_gen_outcome ON resume_generations (outcome);

-- RLS policies
ALTER TABLE career_experiences ENABLE ROW LEVEL SECURITY;
ALTER TABLE resume_generations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can manage their own career experiences"
  ON career_experiences FOR ALL
  USING (auth.uid() = user_id OR user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5');

CREATE POLICY "Users can manage their own resume generations"
  ON resume_generations FOR ALL
  USING (auth.uid() = user_id OR user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5');
;
