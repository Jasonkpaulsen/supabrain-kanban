-- SB-440 part 2: take the rotated token out of every caller.
--
-- The four agent-runner cron commands and the CIP-166 watcher each inlined the old literal.
-- They now build their header block with public.agent_runner_headers(), which reads Vault, so
-- neither cron.job.command nor pg_proc.prosrc carries a secret and neither does this migration.
-- Bodies, schedules, timeouts and project scopes are unchanged.

select cron.alter_job(2, command := $cmd$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["assign"]}'::jsonb)
$cmd$);

select cron.alter_job(3, command := $cmd$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["sweep"]}'::jsonb)
$cmd$);

select cron.alter_job(4, command := $cmd$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["dispatch"],"maxDispatch":5,"dispatchProjects":["90811455-9c92-4f72-b52b-42bdff719937","69195421-285a-4aa5-bad7-7006a0372550","f9f53a8e-f9e7-4217-95e3-cee74662d73a","e54db238-8327-4dbc-8b68-9fe269e1d620"]}'::jsonb,
    timeout_milliseconds:=30000)
$cmd$);

select cron.alter_job(9, command := $cmd$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["dispatch"],"maxDispatch":5,"dispatchProjects":["a07a7f3d-722f-468f-81fa-84e2c5fba704","c89d95d1-e61f-4926-84f0-7b41bb581483","974666aa-eccd-4957-afcf-5d2e15eb29cc","8f71d126-7449-4fa2-ad1b-fa200cb27029","a823caba-9416-4bdf-9bc0-86b3066f1e00","ef6fdb53-9fd1-4d28-a7b8-d48b00074349","42191e55-f88b-4c76-9efe-21c43f6abb8f","219c49e4-9953-41a8-a806-629e7dab00a5","f0c41b99-36ae-4f05-a821-e5a424d8b4e4","90d800b3-e508-47d7-acc9-56c668f7234f","ed8cb7f7-a604-4054-a76e-c3e1114b5316"]}'::jsonb,
    timeout_milliseconds:=120000)
$cmd$);

-- Dead one-shot: its cron job unscheduled itself after firing, and CIP-154 and CIP-149 are both
-- done. It survived only as a body holding a credential.
drop function if exists public.watch_cip154_dispatch149();

-- Still live: CIP-165 is open, so this has not fired. Kept, with the literal replaced. Logic,
-- idempotency guard and one-shot unschedule are unchanged.
create or replace function public.watch_cip165_dispatch166()
returns void
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare
  v_165 text;
  v_kicked text;
  v_req bigint;
  v_be_wip int;
begin
  select status into v_165 from work_items where ticket_code='CIP-165';
  select coalesce(meta->>'resolver_autodispatched','') into v_kicked from work_items where ticket_code='CIP-166';

  -- Trigger only when CIP-165 has finished (done) and we haven't already kicked 166.
  if v_165 = 'done' and v_kicked <> 'true' then
    -- Force-dispatch CIP-166 (bypasses once-per-ticket guard; runner does not check blocked_by).
    select net.http_post(
      url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
      headers:=public.agent_runner_headers(),
      body:='{"phases":["dispatch"],"maxDispatch":1,"forceItems":["CIP-166"],"dispatchProjects":["f9f53a8e-f9e7-4217-95e3-cee74662d73a"]}'::jsonb
    ) into v_req;

    -- Stamp the idempotency guard; move 166 into progress if Back End has a free WIP slot.
    select count(*) into v_be_wip from work_items
      where assignee='CIP Back End Developer' and status='in_progress';
    update work_items
      set status = case when v_be_wip < 5 then 'in_progress' else status end,
          meta = coalesce(meta,'{}'::jsonb) || jsonb_build_object(
                   'resolver_autodispatched','true',
                   'resolver_dispatch_req', v_req,
                   'resolver_dispatched_at', now()::text),
          updated_at = now()
    where ticket_code='CIP-166';

    insert into activity_log(project_id,user_id,agent_name,action,target_table,target_id,summary,meta)
    select 'f9f53a8e-f9e7-4217-95e3-cee74662d73a','5ecbd44a-a3e2-4363-9133-dff3851ba0f5',
           'CIP Project Manager','updated','work_items', id,
           'Auto-dispatched CIP-166 (resolver) — trigger: CIP-165 reached done',
           jsonb_build_object('trigger','CIP-165=done','request_id',v_req,'via','watch-cip165-dispatch166')
    from work_items where ticket_code='CIP-166';

    -- One-shot: remove the watcher now that it has fired.
    perform cron.unschedule('watch-cip165-dispatch166');
  end if;
end;
$function$;

-- Assert the literal is gone from every database surface.
do $$
declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname not in ('pg_catalog','information_schema') and p.prosrc ~ 'agent-run-[A-Za-z0-9]';
  if n > 0 then raise exception 'SB-440: % function body/bodies still contain the literal token', n; end if;

  select count(*) into n from cron.job where command ~ 'agent-run-[A-Za-z0-9]';
  if n > 0 then raise exception 'SB-440: % cron command(s) still contain the literal token', n; end if;
end $$;;
