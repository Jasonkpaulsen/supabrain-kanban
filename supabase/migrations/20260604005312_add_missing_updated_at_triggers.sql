-- OPT-001: Add missing updated_at triggers to 12 tables
-- The update_updated_at() function already exists with SET search_path TO ''

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON agents
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON agent_projects
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON agent_skills
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON build_sessions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON career_experiences
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON career_interview_questions
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON employer_details
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON labels
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON project_skills
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON resume_generations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON work_item_comments
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trigger_update_updated_at
  BEFORE UPDATE ON work_items
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();;
