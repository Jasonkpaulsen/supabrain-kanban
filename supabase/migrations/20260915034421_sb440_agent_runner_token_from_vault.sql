-- SB-440: the agent-runner x-token was embedded as a literal in two database functions,
-- in four cron job commands, in the agent-runner Edge Function source, and -- the reason this
-- is urgent -- in supabase/migrations/20260619021842_schedule_agent_runner.sql, which is
-- committed and pushed to a PUBLIC GitHub repository. Treat the old value as disclosed.
--
-- These two accessors read the rotated token from Vault so that no caller needs to inline it.
-- Neither function returns the secret to an unprivileged caller, and neither contains it, so
-- pg_proc.prosrc -- readable by any role via pg_catalog -- stays clean.

create or replace function public.agent_runner_headers()
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
           'Content-Type', 'application/json',
           'x-token', (select s.decrypted_secret
                         from vault.decrypted_secrets s
                        where s.name = 'agent_runner_token')
         )
$$;

revoke all on function public.agent_runner_headers() from public;

-- The Edge Function validates a presented token without ever receiving the secret itself:
-- it asks "does this match", rather than "what is it".
create or replace function public.agent_runner_token_matches(p_token text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
           p_token = (select s.decrypted_secret
                        from vault.decrypted_secrets s
                       where s.name = 'agent_runner_token'),
           false)
$$;

revoke all on function public.agent_runner_token_matches(text) from public;
grant execute on function public.agent_runner_token_matches(text) to service_role;;
