-- SB-636 (verifier, 2026-10-25): moving an image to a new article clears the old article's pointer.
--
-- set_article_header moves the image (article_id := the new article). When that image was another
-- article's header, that article kept image_asset_id pointing at an image that now belongs
-- elsewhere. The function now clears image_asset_id on every other article the caller can update
-- that points at the image, and reports how many in 'detached'. The UI does not reach this today
-- (only saved/library images and the article's own candidates are offered), so 0 rows change now.
--
-- Correction to 20261025044501: a caller who can see a row but not update it also gets P0002,
-- not 42501, because the FOR UPDATE lock is taken under the UPDATE policy. 42501 remains for a
-- write that matched no row after the lock (it should not happen).

create or replace function public.set_article_header(p_article_id uuid, p_image_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to ''
as $function$
declare v_demoted int; v_detached int;
begin
  if p_article_id is null or p_image_id is null then
    raise exception 'set_article_header: article and image are required' using errcode = '22004';
  end if;
  perform 1 from public.articles where id = p_article_id for update;
  if not found then raise exception 'set_article_header: article not found' using errcode = 'P0002'; end if;
  perform 1 from public.image_assets where id = p_image_id for update;
  if not found then raise exception 'set_article_header: image not found' using errcode = 'P0002'; end if;

  update public.image_assets set status = 'saved'
   where article_id = p_article_id and status = 'accepted' and id <> p_image_id;
  get diagnostics v_demoted = row_count;

  update public.articles set image_asset_id = null
   where image_asset_id = p_image_id and id <> p_article_id;
  get diagnostics v_detached = row_count;

  update public.image_assets set status = 'accepted', article_id = p_article_id where id = p_image_id;
  if not found then raise exception 'set_article_header: image not updated' using errcode = '42501'; end if;

  update public.articles set image_asset_id = p_image_id where id = p_article_id;
  if not found then raise exception 'set_article_header: article not updated' using errcode = '42501'; end if;

  return jsonb_build_object('ok', true, 'article_id', p_article_id, 'image_id', p_image_id,
                            'demoted', v_demoted, 'detached', v_detached);
end;
$function$;

comment on function public.set_article_header(uuid, uuid) is
  'SB-636: make an image the header of an article in one transaction under RLS: demote the old header to saved, clear the pointer on any other article that used the image, accept the image, point articles.image_asset_id at it. Refusals: 22004 null argument, P0002 row not visible or not updatable.';

do $assert$
begin
  if (select prosecdef or proconfig is distinct from array['search_path=""'] from pg_proc
       where oid = 'public.set_article_header(uuid,uuid)'::regprocedure) then
    raise exception 'SB-636: set_article_header must be SECURITY INVOKER with search_path pinned';
  end if;
  if has_function_privilege('anon', 'public.set_article_header(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.set_article_header(uuid,uuid)', 'execute') then
    raise exception 'SB-636: set_article_header grants wrong';
  end if;
  if strpos(pg_get_functiondef('public.set_article_header(uuid,uuid)'::regprocedure),
            'set image_asset_id = null') = 0 then
    raise exception 'SB-636: set_article_header must detach the image from other articles';
  end if;
end
$assert$;