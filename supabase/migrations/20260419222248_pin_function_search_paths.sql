
-- Session 11: pin search_path = public, pg_temp on all six flagged functions.
-- Skill: tech-supabase-security (rule: every public.* function must SET search_path)
-- Advisor will re-run after; expect function_search_path_mutable to drop to 0.

ALTER FUNCTION public.get_dashboard_activity(integer)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.match_skills(extensions.vector, double precision, integer)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.get_table_counts()
  SET search_path = public, pg_temp;

ALTER FUNCTION public.resolve_project_skills(uuid)
  SET search_path = public, pg_temp;

ALTER FUNCTION public.get_schema_info()
  SET search_path = public, pg_temp;

ALTER FUNCTION public.skill_projects(text)
  SET search_path = public, pg_temp;
;
