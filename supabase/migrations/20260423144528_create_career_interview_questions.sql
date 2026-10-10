
-- Structured interview questions organized by role domain
-- Designed to be worked through over multiple sessions
CREATE TABLE career_interview_questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  
  -- Organization
  domain TEXT NOT NULL,           -- role domain: 'ecommerce_dtc', 'digital_transformation', etc.
  domain_label TEXT NOT NULL,     -- human-readable: 'E-Commerce & DTC Leadership'
  question_order INT NOT NULL,    -- sequence within domain
  
  -- The question
  question TEXT NOT NULL,
  context TEXT,                   -- why this question matters for this domain
  
  -- Response tracking
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'answered', 'skipped', 'needs_followup')),
  response TEXT,                  -- Jason's answer
  experiences_created UUID[],     -- career_experiences records created from this answer
  answered_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_interview_q_domain ON career_interview_questions (domain, question_order);
CREATE INDEX idx_interview_q_status ON career_interview_questions (status);
CREATE INDEX idx_interview_q_user ON career_interview_questions (user_id);

ALTER TABLE career_interview_questions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users manage their own interview questions"
  ON career_interview_questions FOR ALL
  USING (auth.uid() = user_id OR user_id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5');
;
