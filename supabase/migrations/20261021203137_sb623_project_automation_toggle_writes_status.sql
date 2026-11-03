-- SB-623: the per-project automation toggle (SB-179) wrote projects.meta.dev_automation, a key
-- SB-390 retired on 2026-08-31 when agent-runner moved its gate to projects.automation_status.
-- The toggle has controlled nothing since. set_project_dev_automation keeps its name and
-- signature (every board calls it) and now writes automation_status; it stays SECURITY INVOKER,
-- so the projects RLS (owner only; restrictive OAuth policies) decides who may flip it. The result
-- carries automation_status plus dev_automation ('on'/'off') for clients still on a cached shell.
-- meta.dev_automation is no longer written and existing values are left as they are.

create or replace function public.set_project_dev_automation(p_project_id uuid, p_on boolean)
 returns jsonb
 language plpgsql
 set search_path = public
as $function$
DECLARE v_name text; v_status text;
BEGIN
  IF p_on IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'p_on is required');
  END IF;
  UPDATE public.projects
     SET automation_status = CASE WHEN p_on THEN 'active' ELSE 'paused' END,
         updated_at = now()
   WHERE id = p_project_id
  RETURNING name, automation_status INTO v_name, v_status;
  IF v_name IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'project not found or not yours'); END IF;
  RETURN jsonb_build_object('ok', true, 'project', v_name, 'automation_status', v_status,
                            'dev_automation', CASE WHEN v_status = 'active' THEN 'on' ELSE 'off' END);
END $function$;

revoke all on function public.set_project_dev_automation(uuid, boolean) from public, anon;
grant execute on function public.set_project_dev_automation(uuid, boolean) to authenticated, service_role;

comment on function public.set_project_dev_automation(uuid, boolean) is
  'SB-623: the board automation toggle. Writes projects.automation_status (active/paused), the flag agent-runner gates on (SB-390). SECURITY INVOKER: RLS limits it to the project owner.';

do $assert$
begin
  if exists (select 1 from pg_proc where oid = 'public.set_project_dev_automation(uuid,boolean)'::regprocedure and prosecdef)
     or has_function_privilege('anon', 'public.set_project_dev_automation(uuid,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.set_project_dev_automation(uuid,boolean)', 'execute') then
    raise exception 'SB-623: set_project_dev_automation posture';
  end if;
  if strpos(pg_get_functiondef('public.set_project_dev_automation(uuid,boolean)'::regprocedure), 'SET automation_status = CASE WHEN p_on') = 0
     or strpos(pg_get_functiondef('public.set_project_dev_automation(uuid,boolean)'::regprocedure), '''dev_automation'', CASE WHEN p_on') > 0 then
    raise exception 'SB-623: set_project_dev_automation does not write automation_status';
  end if;
end
$assert$;
