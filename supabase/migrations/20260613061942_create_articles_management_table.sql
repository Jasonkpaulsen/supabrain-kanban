
-- LCE Article Management table (ADR-LCE-001)
-- System of record for generated LinkedIn articles: review, editorial feedback,
-- approval, optimized scheduling, and trash bin. RLS mirrors work_items/image_assets.

create table if not exists public.articles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  project_id uuid references public.projects(id) on delete set null,
  work_item_id uuid references public.work_items(id) on delete set null,
  title text not null,
  slug text,
  pillar text,
  hook text,
  body_md text,
  word_count integer,
  -- lifecycle: draft -> in_review -> needs_revision -> approved -> scheduled -> published -> trashed
  status text not null default 'draft'
    check (status in ('draft','in_review','needs_revision','approved','scheduled','published','trashed')),
  editorial_feedback text,
  feedback_history jsonb not null default '[]'::jsonb,
  revision_count integer not null default 0,
  sameness_score integer,        -- LCE "Sameness Detector" (lower is better, target <40)
  engagement_score integer,      -- strategist 1-5 score
  header_image_prompt text,
  image_asset_id uuid references public.image_assets(id) on delete set null,
  file_path text,                -- CloudMounter .md path
  scheduled_for timestamptz,     -- optimized publish datetime
  publish_slot_label text,       -- e.g. "Wed 4:00 PM ET — peak"
  published_at timestamptz,
  published_url text,
  trashed_at timestamptz,
  approved_by text,
  approved_at timestamptz,
  source text default 'linkedin-writer',
  meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_articles_user on public.articles(user_id);
create index if not exists idx_articles_project on public.articles(project_id);
create index if not exists idx_articles_status on public.articles(status);
create index if not exists idx_articles_scheduled on public.articles(scheduled_for);

alter table public.articles enable row level security;

create policy "service_role_full" on public.articles
  for all to service_role using (true) with check (true);
create policy "users_select_own" on public.articles
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "users_insert_own" on public.articles
  for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "users_update_own" on public.articles
  for update to authenticated using ((select auth.uid()) = user_id);
create policy "users_delete_own" on public.articles
  for delete to authenticated using ((select auth.uid()) = user_id);

-- keep updated_at fresh + stamp lifecycle timestamps automatically
create or replace function public.articles_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if new.status = 'published' and (old.status is distinct from 'published') and new.published_at is null then
    new.published_at := now();
  end if;
  if new.status = 'trashed' and (old.status is distinct from 'trashed') and new.trashed_at is null then
    new.trashed_at := now();
  end if;
  -- restoring from trash clears the trash timestamp
  if new.status <> 'trashed' and old.status = 'trashed' then
    new.trashed_at := null;
  end if;
  return new;
end $$;

create trigger trg_articles_touch
  before update on public.articles
  for each row execute function public.articles_touch();

comment on table public.articles is 'LCE article management — system of record for generated LinkedIn articles. Lifecycle: draft->in_review->needs_revision->approved->scheduled->published->trashed. ADR-LCE-001.';
;
