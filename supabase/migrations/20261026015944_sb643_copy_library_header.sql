-- SB-643: using a library image as a header copies it instead of moving it.
--
-- Jason, 2026-10-26: "copy library images instead of moving them". set_article_header moved a
-- saved/library image onto the article (status accepted, article_id set), so the image left the
-- library and was purged with the article. Now the article gets its own accepted row on the same
-- storage object (meta.copied_from = the library row) and the library row is not touched.
--
-- storage_path is not unique, and both removal paths keep a file another row still uses (SB-633),
-- so removing the article removes only the copy row and deleting the library image keeps the file
-- the copy uses. A header copy that is later replaced becomes rejected rather than saved, so the
-- library never lists one image twice; lce-cleanup purges it after the grace period.
--
-- SB-627 kept image_assets inserts service-role only so no row could be forged to reach another
-- user's file. A copy reaches no file the caller could not already read, so the trigger now lets a
-- signed-in user insert a row for a bucket and path they already have a row for. The lookup runs
-- as the caller (the trigger is not SECURITY DEFINER), so RLS and the explicit user_id test limit
-- it to their own rows; anon is still refused. Path and bucket changes stay service-role only.

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

  -- The replaced header goes back to the library, unless it is a copy (SB-643): then it is rejected.
  update public.image_assets set status = case when meta ? 'copied_from' then 'rejected' else 'saved' end
   where article_id = p_article_id and status = 'accepted' and id <> p_image_id;
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

comment on function public.set_article_header(uuid, uuid) is
  'SB-636/SB-643: make an image the header of an article in one transaction under RLS. A saved or library image is copied (new accepted row on the same file, meta.copied_from; the library row is unchanged); any other image moves, and other articles that pointed at it are detached. The replaced header goes to saved, or to rejected if it was a copy. Refusals: 22004 null argument, P0002 row not visible or not updatable.';

do $assert$
declare d text := pg_get_functiondef('public.set_article_header(uuid,uuid)'::regprocedure);
        t text := pg_get_functiondef('public.enforce_image_asset_path_service_only()'::regprocedure);
begin
  if (select prosecdef or proconfig is distinct from array['search_path=""'] from pg_proc
       where oid = 'public.set_article_header(uuid,uuid)'::regprocedure) then
    raise exception 'SB-643: set_article_header must stay SECURITY INVOKER with search_path pinned';
  end if;
  if has_function_privilege('anon', 'public.set_article_header(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.set_article_header(uuid,uuid)', 'execute') then
    raise exception 'SB-643: set_article_header grants changed';
  end if;
  if strpos(d, 'copied_from') = 0 or strpos(d, 'set image_asset_id = null') = 0 then
    raise exception 'SB-643: set_article_header must copy library images and still detach moved ones';
  end if;
  if (select prosecdef or proconfig is distinct from array['search_path=""'] from pg_proc
       where oid = 'public.enforce_image_asset_path_service_only()'::regprocedure)
     or strpos(t, 'ia.user_id = (select auth.uid())') = 0 then
    raise exception 'SB-643: the path trigger must stay invoker and allow only copies of the caller''s own rows';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_image_asset_path_service_only'
                   and tgrelid = 'public.image_assets'::regclass and tgenabled = 'O') then
    raise exception 'SB-643: trg_image_asset_path_service_only missing or disabled';
  end if;
end
$assert$;