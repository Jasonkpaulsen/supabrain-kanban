
-- Create ef_assessments table
CREATE TABLE public.ef_assessments (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  child_name text NOT NULL,
  assessment_date date NOT NULL,
  skill_name text NOT NULL CHECK (skill_name IN (
    'Response Inhibition',
    'Working Memory',
    'Emotional Control',
    'Sustained Attention',
    'Task Initiation',
    'Planning/Prioritization',
    'Organization',
    'Time Management',
    'Flexibility',
    'Metacognition',
    'Goal-Directed Persistence',
    'Stress Tolerance'
  )),
  self_rating integer CHECK (self_rating BETWEEN 1 AND 5),
  parent_rating integer CHECK (parent_rating BETWEEN 1 AND 5),
  notes text,
  quarter text,
  created_at timestamptz DEFAULT now(),
  user_id uuid REFERENCES auth.users(id)
);

-- Enable RLS
ALTER TABLE public.ef_assessments ENABLE ROW LEVEL SECURITY;

-- Policy: users can read/write their own rows
CREATE POLICY "Users can manage their own ef_assessments"
  ON public.ef_assessments
  FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
;
