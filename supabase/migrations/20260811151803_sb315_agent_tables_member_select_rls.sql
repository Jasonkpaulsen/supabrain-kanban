-- SB-315: project-member SELECT visibility for agent tables.
-- Additive PERMISSIVE SELECT policies only. Owner-only writes and service_role are untouched.

-- 1) SECURITY DEFINER wrapper: "can this user reach this agent via any project they are a member of?"
CREATE OR REPLACE FUNCTION public.can_access_agent(p_agent_id uuid, p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM agent_projects ap
    WHERE ap.agent_id = p_agent_id
      AND is_project_member(ap.project_id, p_user_id)
  );
$function$;

-- 2) agents: member can SELECT an agent linked (via agent_projects) to any project they belong to.
CREATE POLICY members_select_via_project
  ON public.agents
  FOR SELECT
  TO authenticated
  USING ( can_access_agent(id, (SELECT auth.uid())) );

-- 3) agent_projects: member can SELECT the specific link rows for projects they belong to.
CREATE POLICY members_select_via_project
  ON public.agent_projects
  FOR SELECT
  TO authenticated
  USING ( is_project_member(project_id, (SELECT auth.uid())) );

-- 4) agent_skills: no project_id column — reach project membership through agent_projects on agent_id.
CREATE POLICY members_select_via_project
  ON public.agent_skills
  FOR SELECT
  TO authenticated
  USING ( can_access_agent(agent_id, (SELECT auth.uid())) );;
