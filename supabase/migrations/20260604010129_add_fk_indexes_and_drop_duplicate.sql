-- OPT-002: Add missing FK indexes
CREATE INDEX IF NOT EXISTS idx_agent_projects_user_id ON agent_projects (user_id);
CREATE INDEX IF NOT EXISTS idx_agent_skills_user_id ON agent_skills (user_id);
CREATE INDEX IF NOT EXISTS idx_employer_details_user_id ON employer_details (user_id);
CREATE INDEX IF NOT EXISTS idx_resume_gen_job_app ON resume_generations (job_application_id);

-- OPT-003: Drop duplicate index on profiles
DROP INDEX IF EXISTS idx_profiles_user;;
