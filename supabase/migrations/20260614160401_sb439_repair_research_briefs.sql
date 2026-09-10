-- SB-439: repair — research_briefs, a table production has and no migration creates.
--
-- Four kel_029 migrations from 20260614160402 onward ALTER this table, but nothing
-- ever built it. Placed at 20260614160401, immediately before the first of them.
--
-- Deliberately the pre-kel_029 shape: market_category, series_ticker,
-- research_run_id and source_brief_id, their indexes, and chk_market_category all
-- arrive in those four migrations and are not pre-empted here.
--
-- oauth_client_deny is absent for the same reason as in the agent_runs repair —
-- SB-409 adds it later by sweeping every RLS-enabled table.

create table if not exists public.research_briefs (
  id uuid not null default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  project_id uuid not null,
  market_ticker text not null,
  event_ticker text,
  market_title text,
  venue text not null default 'kalshi'::text,
  research_type text not null default 'market_scan'::text,
  summary text not null,
  thesis text,
  model_inputs jsonb not null default '{}'::jsonb,
  data_sources jsonb not null default '[]'::jsonb,
  confidence_assessment jsonb not null default '{}'::jsonb,
  snapshot_price_cents numeric,
  snapshot_volume_24h numeric,
  snapshot_open_interest numeric,
  snapshot_orderbook jsonb,
  close_time timestamptz,
  status text not null default 'draft'::text,
  created_by_agent text not null default 'atlas'::text,
  consumed_by_agent text,
  consumed_at timestamptz,
  expires_at timestamptz,
  stale_reason text,
  parent_brief_id uuid,
  supersedes_brief_id uuid,
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint research_briefs_pkey primary key (id),
  constraint research_briefs_project_id_fkey foreign key (project_id) references public.projects(id),
  constraint research_briefs_parent_brief_id_fkey foreign key (parent_brief_id) references public.research_briefs(id),
  constraint research_briefs_supersedes_brief_id_fkey foreign key (supersedes_brief_id) references public.research_briefs(id),
  constraint valid_rb_venue check (venue = 'kalshi'::text),
  constraint valid_rb_research_type check (research_type = any (array['market_scan'::text,'deep_dive'::text,'live_update'::text,'follow_up'::text])),
  constraint valid_rb_status check (status = any (array['draft'::text,'published'::text,'consumed'::text,'stale'::text]))
);

create index if not exists idx_rb_created_at    on public.research_briefs using btree (created_at desc);
create index if not exists idx_rb_user_project  on public.research_briefs using btree (user_id, project_id);
create index if not exists idx_rb_status_market on public.research_briefs using btree (status, market_ticker) where (status = 'published'::text);
create index if not exists idx_rb_expires       on public.research_briefs using btree (expires_at) where ((expires_at is not null) and (status = 'published'::text));

alter table public.research_briefs enable row level security;

drop policy if exists rb_owner_select on public.research_briefs;
create policy rb_owner_select on public.research_briefs for select
  using ((auth.uid() = user_id));
drop policy if exists rb_owner_insert on public.research_briefs;
create policy rb_owner_insert on public.research_briefs for insert
  with check ((auth.uid() = user_id));
drop policy if exists rb_owner_update_draft on public.research_briefs;
create policy rb_owner_update_draft on public.research_briefs for update
  using (((auth.uid() = user_id) and (status = 'draft'::text)))
  with check ((auth.uid() = user_id));
drop policy if exists rb_owner_mark_consumed on public.research_briefs;
create policy rb_owner_mark_consumed on public.research_briefs for update
  using (((auth.uid() = user_id) and (status = 'published'::text)))
  with check (((auth.uid() = user_id) and (status = any (array['consumed'::text,'stale'::text]))));
