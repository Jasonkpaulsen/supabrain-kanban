-- SB-643 (verification, 2026-10-26): an image row can be attached only to the caller's own article,
-- and a replaced header copy goes back to the library when no library row still has its file.
--
-- 1. image_assets RLS checks only user_id, and the article_id foreign key ignores RLS, so a signed-in
--    user could put their own row on another user's article (by INSERT, which SB-643 opened, or by
--    UPDATE, possible since before). With status 'accepted' it takes that article's slot in
--    image_assets_one_accepted_per_article; the owner cannot see it, so every set_article_header
--    on that article then fails with 23505, and lce-cleanup can no longer purge the article.
--    The guard trigger now refuses, for anon and authenticated, a non-null article_id on INSERT,
--    or a changed one on UPDATE, unless the caller owns that article. Articles are owner-only
--    (users_*_own), and no row today points at another user's article.
-- 2. set_article_header rejected every replaced copy. If the library row it came from had been
--    deleted (its file kept because the copy used it), the copy was the last row for the image and
--    lce-cleanup would purge it and the file. Such a copy now goes back to the library as saved.

create or replace function public.enforce_image_asset_path_service_only()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      if current_user = 'anon' or not exists (
           select 1 from public.image_assets ia
            where ia.storage_bucket = new.storage_bucket and ia.storage_path = new.storage_path
              and ia.user_id = (select auth.uid()) and new.user_id = (select auth.uid())) then
        raise exception 'SB-627: image_assets rows are created by the service role only (SB-643: or as a copy of your own image)'
          using errcode = '42501';
      end if;
    elsif new.storage_path is distinct from old.storage_path or new.storage_bucket is distinct from old.storage_bucket then
      raise exception 'SB-627: storage_path and storage_bucket are set by the service role only'
        using errcode = '42501';
    end if;
    if new.article_id is not null and (tg_op = 'INSERT' or new.article_id is distinct from old.article_id)
       and not exists (select 1 from public.articles a where a.id = new.article_id and a.user_id = (select auth.uid())) then
      raise exception 'SB-643: an image can be attached only to your own article' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.set_article_header(p_article_id uuid, p_image_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to ''
as $function$
declare
  v_src public.image_assets%rowtype;
  v_target uuid;
  v_copied uuid;
  v_demoted int := 0;
  v_detached int := 0;
begin
  if p_article_id is null or p_image_id is null then
    raise exception 'set_article_header: article and image are required' using errcode = '22004';
  end if;
  perform 1 from public.articles where id = p_article_id for update;
  if not found then raise exception 'set_article_header: article not found' using errcode = 'P0002'; end if;
  select * into v_src from public.image_assets where id = p_image_id for update;
  if not found then raise exception 'set_article_header: image not found' using errcode = 'P0002'; end if;

  if v_src.status in ('saved', 'library') then
    -- SB-643: the article's header is already a copy of this library image: nothing to do.
    select id into v_target from public.image_assets
     where article_id = p_article_id and status = 'accepted' and meta->>'copied_from' = p_image_id::text;
    if found then
      update public.articles set image_asset_id = v_target where id = p_article_id and image_asset_id is distinct from v_target;
      return jsonb_build_object('ok', true, 'article_id', p_article_id, 'image_id', v_target,
                                'copied_from', p_image_id, 'demoted', 0, 'detached', 0);
    end if;
  end if;

  -- The replaced header goes back to the library, unless it is a copy whose file a library row
  -- still has (SB-643): then it is rejected, so the library does not list the image twice.
  update public.image_assets ia
     set status = case when ia.meta ? 'copied_from' and exists (
                         select 1 from public.image_assets s
                          where s.storage_bucket = ia.storage_bucket and s.storage_path = ia.storage_path
                            and s.status in ('saved', 'library'))
                       then 'rejected' else 'saved' end
   where ia.article_id = p_article_id and ia.status = 'accepted' and ia.id <> p_image_id;
  get diagnostics v_demoted = row_count;

  if v_src.status in ('saved', 'library') then
    insert into public.image_assets (user_id, project_id, storage_path, storage_bucket, public_url, original_filename,
                                     file_size_bytes, mime_type, description, tags, extracted_text, image_type,
                                     objects_detected, embedding, meta, analysis_status, analysis_error, prompt,
                                     article_id, status, sort_order)
    values (v_src.user_id, v_src.project_id, v_src.storage_path, v_src.storage_bucket, v_src.public_url, v_src.original_filename,
            v_src.file_size_bytes, v_src.mime_type, v_src.description, v_src.tags, v_src.extracted_text, v_src.image_type,
            v_src.objects_detected, v_src.embedding, coalesce(v_src.meta, '{}'::jsonb) || jsonb_build_object('copied_from', v_src.id),
            v_src.analysis_status, v_src.analysis_error, v_src.prompt,
            p_article_id, 'accepted', 0)
    returning id into v_target;
    v_copied := v_src.id;
  else
    update public.articles set image_asset_id = null
     where image_asset_id = p_image_id and id <> p_article_id;
    get diagnostics v_detached = row_count;
    update public.image_assets set status = 'accepted', article_id = p_article_id where id = p_image_id;
    if not found then raise exception 'set_article_header: image not updated' using errcode = '42501'; end if;
    v_target := p_image_id;
  end if;

  update public.articles set image_asset_id = v_target where id = p_article_id;
  if not found then raise exception 'set_article_header: article not updated' using errcode = '42501'; end if;

  return jsonb_build_object('ok', true, 'article_id', p_article_id, 'image_id', v_target,
                            'copied_from', v_copied, 'demoted', v_demoted, 'detached', v_detached);
end;
$function$;

do $assert$
declare d text := pg_get_functiondef('public.set_article_header(uuid,uuid)'::regprocedure);
        t text := pg_get_functiondef('public.enforce_image_asset_path_service_only()'::regprocedure);
begin
  if (select prosecdef or proconfig is distinct from array['search_path=""'] from pg_proc
       where oid = 'public.set_article_header(uuid,uuid)'::regprocedure)
     or (select prosecdef or proconfig is distinct from array['search_path=""'] from pg_proc
       where oid = 'public.enforce_image_asset_path_service_only()'::regprocedure) then
    raise exception 'SB-643: set_article_header and the guard must stay invoker with search_path pinned';
  end if;
  if strpos(t, 'a.id = new.article_id and a.user_id = (select auth.uid())') = 0
     or strpos(t, 'ia.user_id = (select auth.uid())') = 0 then
    raise exception 'SB-643: the guard must check article ownership and keep the own-row copy rule';
  end if;
  if strpos(d, 'copied_from') = 0 or strpos(d, 's.status in (''saved'', ''library'')') = 0 then
    raise exception 'SB-643: set_article_header must reject a replaced copy only while a library row has its file';
  end if;
  if exists (select 1 from public.image_assets i join public.articles a on a.id = i.article_id where a.user_id <> i.user_id) then
    raise exception 'SB-643: an image row points at another user''s article';
  end if;
end
$assert$;