-- SB-439: repair — agent_runs, a table production has and no migration creates.
--
-- SB-419 adds eight lineage columns to this table and the whole agent execution
-- path writes to it, but nothing in the history ever built it. Placed at
-- 20260531010318: immediately after agents (20260531010317), which it references,
-- and well before its first appearance in a migration (20260612205700).
--
-- Deliberately the PRE-SB-419 shape. The eight lineage columns, their foreign keys,
-- the not-self-parent check and the 'cancelled' status value all arrive in
-- 20260907035027 and must not be pre-empted here — SB-419 locates the existing
-- status CHECK by looking for one that does NOT mention 'cancelled', so creating it
-- with 'cancelled' already present would make that migration silently skip its work.
--
-- Two policies present in production are deliberately absent:
--   oauth_client_deny        — added by SB-409's sweep over every RLS-enabled table
--   classroom_writer_heartbeat — depends on the classroom_writer login role, which
--                                is itself created outside the migration history and
--                                will not exist on a replayed branch. Recorded on
--                                SB-439 as known, accepted drift rather than papered
--                                over with a role this history cannot create.

create table if not exists public.agent_runs (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null,
  agent_id uuid not null,
  work_item_id uuid,
  project_id uuid,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  duration_ms integer generated always as (
    case when finished_at is not null
         then (extract(epoch from (finished_at - started_at)))::integer * 1000
         else null::integer end) stored,
  status text not null default 'running'::text,
  tokens_input integer default 0,
  tokens_output integer default 0,
  tokens_total integer generated always as (coalesce(tokens_input, 0) + coalesce(tokens_output, 0)) stored,
  tool_calls integer default 0,
  api_calls integer default 0,
  result_summary text,
  error_message text,
  error_code text,
  items_created integer default 0,
  items_updated integer default 0,
  trigger_type text default 'manual'::text,
  run_metadata jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint agent_runs_pkey primary key (id),
  constraint agent_runs_user_id_fkey foreign key (user_id) references auth.users(id) on delete cascade,
  constraint agent_runs_agent_id_fkey foreign key (agent_id) references public.agents(id) on delete cascade,
  constraint agent_runs_work_item_id_fkey foreign key (work_item_id) references public.work_items(id) on delete set null,
  constraint agent_runs_project_id_fkey foreign key (project_id) references public.projects(id) on delete set null,
  constraint agent_runs_status_check check (status = any (array['running'::text,'completed'::text,'failed'::text,'timeout'::text])),
  constraint agent_runs_trigger_type_check check (trigger_type = any (array['manual'::text,'scheduled'::text,'jarvis_sweep'::text,'webhook'::text,'chain'::text]))
);

create index if not exists idx_agent_runs_agent         on public.agent_runs using btree (agent_id);
create index if not exists idx_agent_runs_agent_started on public.agent_runs using btree (agent_id, started_at desc);
create index if not exists idx_agent_runs_perf          on public.agent_runs using btree (agent_id, status, started_at desc);
create index if not exists idx_agent_runs_project       on public.agent_runs using btree (project_id);
create index if not exists idx_agent_runs_started       on public.agent_runs using btree (started_at desc);
create index if not exists idx_agent_runs_status        on public.agent_runs using btree (status) where (status <> 'completed'::text);
create index if not exists idx_agent_runs_user          on public.agent_runs using btree (user_id);
create index if not exists idx_agent_runs_work_item     on public.agent_runs using btree (work_item_id) where (work_item_id is not null);

alter table public.agent_runs enable row level security;

drop policy if exists users_select_own on public.agent_runs;
create policy users_select_own on public.agent_runs for select using ((select auth.uid()) = user_id);
drop policy if exists users_insert_own on public.agent_runs;
create policy users_insert_own on public.agent_runs for insert with check ((select auth.uid()) = user_id);
drop policy if exists users_update_own on public.agent_runs;
create policy users_update_own on public.agent_runs for update using ((select auth.uid()) = user_id);
drop policy if exists users_delete_own on public.agent_runs;
create policy users_delete_own on public.agent_runs for delete using ((select auth.uid()) = user_id);
