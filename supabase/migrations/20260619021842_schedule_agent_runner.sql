-- SB-241: schedule the agent runner.
-- Intake (auto-assign) every 15 min; flow/governance sweep once daily (19:00 ET = 23:00 UTC).
SELECT cron.schedule('agent-runner-assign', '*/15 * * * *', $$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:='{"Content-Type":"application/json","x-token":"agent-run-9Fp3xQ2mWz"}'::jsonb,
    body:='{"phases":["assign"]}'::jsonb)
$$);

SELECT cron.schedule('agent-runner-sweep', '0 23 * * *', $$
  select net.http_post(
    url:='https://hzqqvbvhnzmgqivfigej.supabase.co/functions/v1/agent-runner',
    headers:='{"Content-Type":"application/json","x-token":"agent-run-9Fp3xQ2mWz"}'::jsonb,
    body:='{"phases":["sweep"]}'::jsonb)
$$);;
