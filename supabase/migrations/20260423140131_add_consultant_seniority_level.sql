
ALTER TABLE career_experiences DROP CONSTRAINT career_experiences_seniority_level_check;
ALTER TABLE career_experiences ADD CONSTRAINT career_experiences_seniority_level_check 
  CHECK (seniority_level IN ('ic', 'consultant', 'manager', 'director', 'vp', 'svp', 'c_level'));
;
