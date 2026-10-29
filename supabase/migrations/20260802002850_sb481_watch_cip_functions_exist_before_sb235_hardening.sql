-- SB-481: repair. The two watch_cip functions SB-439 deliberately left out must
-- exist before the SB-235 hardening migrations touch them.
--
-- 20260802002858, 20260802002935 and 20260802003018 each REVOKE on or ALTER
-- public.watch_cip154_dispatch149() and public.watch_cip165_dispatch166(). On a
-- fresh replay neither exists at that point: 20260419222247_sb439_repair_missing_
-- functions omitted both on purpose, because each embedded a literal auth token
-- readable through pg_proc, and recorded the omission as blocked on SB-440.
-- SB-440 has since landed (20260915034421, 20260915034810): cip154 was dropped
-- from production, cip165 recreated with the token read from Vault. The replay
-- stops at 172 of 266 (SB-439 cycle 6, 2026-09-20).
--
-- The references cannot simply be skipped. Production's cip165 is SECURITY
-- DEFINER with PUBLIC revoked, and that ACL is produced by the SB-235
-- migrations, not by the 20260915 recreate. A branch that skipped them would
-- hold a PUBLIC-executable SECURITY DEFINER function production does not have.
--
-- Placed at 20260802002850: strictly after 20260802002842 (the last migration
-- the replay applied) and strictly before 20260802002858 (the first reference).
--
-- 1. watch_cip165_dispatch166 -- body rendered from the production catalog with
--    pg_get_functiondef, not transcribed. Baseline: oid 38829, definition md5
--    ceacc15f9f0939d2435f898b82dc12be, 2217 chars. Vault-reading; contains no
--    secret. SB-235 then hardens it exactly as it did in production and the
--    20260915034810 CREATE OR REPLACE becomes a true replace.
--
-- 2. watch_cip154_dispatch149 -- a PLACEHOLDER, and labelled as one. The real
--    function existed in production from April to September 2026; its only body
--    held a credential and is not reproduced here, deliberately. This no-op
--    SECURITY INVOKER stub exists on the replay for the interval the real one
--    existed, receives the same SB-235 hardening, and is dropped by
--    20260915034810 (drop function if exists), so the replay ends where
--    production is: without it.
--
-- On production this row is recorded as applied without having run, the
-- treatment the SB-439, SB-478 and SB-480 repairs received under the decision
-- "Option B -- supabase migration repair --status applied". CREATE OR REPLACE of
-- a byte-identical cip165, and a stub for a function production no longer has:
-- the end state is unchanged by construction.
--
-- The cip165 body calls public.agent_runner_headers(), which the history creates
-- at 20260915034421. plpgsql checks syntax at CREATE time and does not resolve
-- calls inside embedded SQL, and nothing executes this function during a replay.
CREATE OR REPLACE FUNCTION public.watch_cip165_dispatch166()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
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

-- Placeholder. See item 2 in the header: not the body production ran.
CREATE OR REPLACE FUNCTION public.watch_cip154_dispatch149()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  -- SB-481 placeholder for a one-shot cron helper whose real body held a
  -- credential. Dropped by 20260915034810.
  RETURN;
END;
$function$;
