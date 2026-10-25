-- SB-636: changing an article's header image is one transaction.
--
-- Article Studio's acceptImage and useLibraryImage each made three separate writes (demote the
-- current header, accept the new image, point articles.image_asset_id at it), mostly unchecked.
-- A failure part-way left the old header demoted while the article still pointed at it, or two
-- accepted images. set_article_header does the three writes in one transaction and raises if any
-- of them does not land, so the client sees either the new header or an error and no change.
--
-- SECURITY INVOKER with search_path '': RLS still decides. A caller who cannot see the article
-- or the image gets "not found"; one who can see but not update them gets 42501. The partial
-- unique index makes "one accepted image per article" a database rule (0 violations today).
-- Reusing a library image keeps today's behaviour: it moves to the article as its header.

create unique index if not exists image_assets_one_accepted_per_article
  on public.image_assets (article_id) where status = 'accepted';

create or replace function public.set_article_header(p_article_id uuid, p_image_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to ''
as $function$
declare v_demoted int;
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

  update public.image_assets set status = 'accepted', article_id = p_article_id where id = p_image_id;
  if not found then raise exception 'set_article_header: image not updated' using errcode = '42501'; end if;

  update public.articles set image_asset_id = p_image_id where id = p_article_id;
  if not found then raise exception 'set_article_header: article not updated' using errcode = '42501'; end if;

  return jsonb_build_object('ok', true, 'article_id', p_article_id, 'image_id', p_image_id, 'demoted', v_demoted);
end;
$function$;

comment on function public.set_article_header(uuid, uuid) is
  'SB-636: make an image the header of an article in one transaction under RLS: demote the old header to saved, accept the image, point articles.image_asset_id at it.';

revoke all on function public.set_article_header(uuid, uuid) from public, anon;
grant execute on function public.set_article_header(uuid, uuid) to authenticated, service_role;

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
  if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'image_assets_one_accepted_per_article'
                  and indexdef like '%UNIQUE%(article_id) WHERE (status = ''accepted''::text)') then
    raise exception 'SB-636: unique accepted index missing';
  end if;
end
$assert$;