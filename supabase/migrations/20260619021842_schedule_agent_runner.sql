-- SB-241: schedule the agent runner.
-- Intake (auto-assign) every 15 min; flow/governance sweep once daily (19:00 ET = 23:00 UTC).
-- SB-494 (2026-10-01): amended under ADR-DL-003. The headers were a literal token
-- (dead since its 2026-09-15 rotation); they now read the Vault helper the live
-- jobs have used since SB-440. Same text in schema_migrations; md5 parity kept.
SELECT cron.schedule('agent-runner-assign', '*/15 * * * *', $$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["assign"]}'::jsonb)
$$);

SELECT cron.schedule('agent-runner-sweep', '0 23 * * *', $$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:=public.agent_runner_headers(),
    body:='{"phases":["sweep"]}'::jsonb)
$$);;
