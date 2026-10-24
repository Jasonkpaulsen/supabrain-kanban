-- 1. Restrict the over-permissive ALL policy from {public} (incl. anon) to service_role only,
--    matching the correct pattern already on agents/projects. The users_*_own policies
--    (auth.uid() = user_id) continue to govern signed-in access; anon (auth.uid() IS NULL) is blocked.
alter policy "service_role_full" on public.work_items to service_role;
alter policy "service_role_full" on public.work_item_comments to service_role;
alter policy "service_role_full" on public.work_item_labels to service_role;
alter policy "service_role_full" on public.labels to service_role;

-- 2. Revoke anonymous access to the SECURITY DEFINER views (they bypass RLS, so anon must not query them).
revoke all on public.kanban_board_view from anon;
revoke all on public.vw_pipeline_integrity_violations from anon;

-- 3. Lock down the anon-executable SECURITY DEFINER RPCs; keep them for signed-in users + service_role.
revoke execute on function public.move_work_item(uuid, text, integer) from public, anon;
grant execute on function public.move_work_item(uuid, text, integer) to authenticated, service_role;
revoke execute on function public.assign_agent_to_item(uuid, uuid) from public, anon;
grant execute on function public.assign_agent_to_item(uuid, uuid) to authenticated, service_role;;
