
-- Image curation: per-article candidate sets, accept/reject/save, reusable library, request queue.
alter table public.image_assets
  add column if not exists article_id uuid references public.articles(id) on delete set null,
  add column if not exists status text default 'library',
  add column if not exists set_id uuid,
  add column if not exists prompt text,
  add column if not exists feedback text,
  add column if not exists sort_order integer default 0;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='image_assets_status_chk') then
    alter table public.image_assets add constraint image_assets_status_chk
      check (status in ('candidate','accepted','rejected','saved','library','published'));
  end if;
end $$;

create index if not exists idx_imgassets_article on public.image_assets(article_id);
create index if not exists idx_imgassets_status on public.image_assets(status);
create index if not exists idx_imgassets_set on public.image_assets(set_id);

create table if not exists public.image_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid(),
  article_id uuid references public.articles(id) on delete cascade,
  prompt text,
  feedback text,
  count integer not null default 3,
  status text not null default 'pending' check (status in ('pending','processing','done','failed')),
  set_id uuid,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_imgreq_status on public.image_requests(status);
create index if not exists idx_imgreq_article on public.image_requests(article_id);

alter table public.image_requests enable row level security;
create policy "service_role_full" on public.image_requests for all to service_role using (true) with check (true);
create policy "users_select_own" on public.image_requests for select to authenticated using ((select auth.uid()) = user_id);
create policy "users_insert_own" on public.image_requests for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "users_update_own" on public.image_requests for update to authenticated using ((select auth.uid()) = user_id);
create policy "users_delete_own" on public.image_requests for delete to authenticated using ((select auth.uid()) = user_id);

comment on table public.image_requests is 'Queue of header-image generation requests from Article Studio. An agent/edge function fulfills pending rows, creating candidate image_assets. ADR-LCE-001.';
;
