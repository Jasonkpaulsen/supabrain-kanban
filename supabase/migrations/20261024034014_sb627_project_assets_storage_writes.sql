-- SB-627: only the service role writes to project-assets; a signed-in user may remove only
-- their own image files.
--
-- The three write policies on storage.objects for project-assets ("Allow uploads",
-- "Allow updates", "Allow deletes", 2026-03-28) applied to PUBLIC and checked only the bucket.
-- Any visitor holding the publishable key could upload (each image upload makes
-- trigger_image_analysis post to analyze-image, a paid call), overwrite or remove any asset.
--
-- Who writes today (2026-10-24): all 13 objects have owner null and an image_assets row.
-- lce-image-ingest uploads and lce-cleanup removes with the service-role key, which bypasses
-- RLS, so neither depends on these policies. The one client writer is article-studio's
-- deleteStorage: it removes an image's file as the signed-in user, before removing the
-- image_assets row. No client uploads or updates exist.
--
-- 1. "Allow uploads" and "Allow updates" go TO service_role: anon and authenticated lose both.
-- 2. "Allow deletes" goes TO authenticated, for objects whose image_assets row the caller owns.
-- 3. project_assets_select_own (new) uses the same rule. Storage API removals read the rows
--    they remove, and SELECT policies apply to that read, so (2) needs it. Public reads use
--    /object/public and do not go through these policies; the broad listing policy dropped on
--    2026-04-19 stays dropped.
-- The policies keep their names: postgres may change a storage.objects policy's roles and
-- expressions but may not rename it (not the table owner).

create temp table sb627_before as
select polname, polcmd, polroles, polpermissive, pg_get_expr(polqual, polrelid) q, pg_get_expr(polwithcheck, polrelid) w
  from pg_policy where polrelid = 'storage.objects'::regclass;

alter policy "Allow uploads" on storage.objects to service_role;
alter policy "Allow updates" on storage.objects to service_role;
alter policy "Allow deletes" on storage.objects to authenticated using (
  bucket_id = 'project-assets' and exists (select 1 from public.image_assets ia
    where ia.storage_bucket = 'project-assets' and ia.storage_path = objects.name and ia.user_id = (select auth.uid())));
create policy project_assets_select_own on storage.objects for select to authenticated using (
  bucket_id = 'project-assets' and exists (select 1 from public.image_assets ia
    where ia.storage_bucket = 'project-assets' and ia.storage_path = objects.name and ia.user_id = (select auth.uid())));

do $assert$
declare bad text; own_rule text;
begin
  -- uploads and updates: same command, permissive flag and expressions; only the roles changed
  select string_agg(b.polname, ', ') into bad from sb627_before b
    join pg_policy p on p.polrelid = 'storage.objects'::regclass and p.polname = b.polname
   where b.polname in ('Allow uploads', 'Allow updates')
     and (p.polcmd is distinct from b.polcmd or p.polpermissive is distinct from b.polpermissive
          or pg_get_expr(p.polqual, p.polrelid) is distinct from b.q or pg_get_expr(p.polwithcheck, p.polrelid) is distinct from b.w
          or p.polroles <> array['service_role'::regrole]::oid[]);
  if bad is not null then raise exception 'SB-627: % not service-role only', bad; end if;

  select pg_get_expr(polqual, polrelid) into own_rule from pg_policy where polrelid = 'storage.objects'::regclass and polname = 'project_assets_select_own';
  if own_rule is null
     or (select pg_get_expr(polqual, polrelid) from pg_policy where polrelid = 'storage.objects'::regclass and polname = 'Allow deletes') is distinct from own_rule
     or strpos(own_rule, '(ia.user_id = ( SELECT auth.uid() AS uid))') = 0 or strpos(own_rule, '(ia.storage_path = objects.name)') = 0
     or exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass and polname in ('Allow deletes', 'project_assets_select_own')
                and (polroles <> array['authenticated'::regrole]::oid[] or not polpermissive)) then
    raise exception 'SB-627: remove/select owner rule wrong';
  end if;

  -- no project-assets policy left for PUBLIC or anon, and nothing else on storage.objects
  if exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
              and (0::oid = any(polroles) or 'anon'::regrole::oid = any(polroles))) then
    raise exception 'SB-627: a storage.objects policy still applies to PUBLIC or anon';
  end if;
  if (select count(*) from pg_policy where polrelid = 'storage.objects'::regclass) <> (select count(*) from sb627_before) + 1 then
    raise exception 'SB-627: unexpected storage.objects policy count';
  end if;
  if (select count(*) from storage.objects where bucket_id = 'project-assets') <> 13
     or not (select public from storage.buckets where id = 'project-assets') then
    raise exception 'SB-627: bucket or objects changed';
  end if;
end
$assert$;