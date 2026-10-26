-- Article header suite: TC-SB636-01 (SB-636), TC-SB643-01 (SB-643: library images are copied).
--
-- Run as postgres. One transaction that always ends by raising, so the fixture articles and
-- images do not survive. Pass = the raised message starts with "ARTICLE_HEADER PASS". The message
-- carries only check names.
--
-- Fixture: O owns article A with an accepted header h0, a candidate c1 and a saved library image
-- lib; X owns article B and image xi. O's article A2 has header m (TC-SB636-01.move_detaches, verifier
-- 2026-10-25: moving m to A clears A2's pointer). lib2 is a 'library'-status image (SB-643).

do $suite$
declare
  r jsonb := '{}'::jsonb; fails int; st text; res jsonb;
  o constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  x constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  a uuid; b uuid; a2 uuid; h0 uuid; c1 uuid; lib uuid; lib2 uuid; xi uuid; m uuid; snap text; cp uuid; cp2 uuid;
begin
  insert into public.articles (user_id, title, status) values (o, 'qa-sb636 A', 'draft') returning id into a;
  insert into public.articles (user_id, title, status) values (x, 'qa-sb636 B', 'draft') returning id into b;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/h0.png', o, a, 'accepted') returning id into h0;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/c1.png', o, a, 'candidate') returning id into c1;
  insert into public.image_assets (storage_path, user_id, article_id, status, description) values ('qa-sb636/lib.png', o, null, 'saved', 'qa lib') returning id into lib;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/lib2.png', o, null, 'library') returning id into lib2;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/xi.png', x, b, 'candidate') returning id into xi;
  update public.articles set image_asset_id = h0 where id = a;
  insert into public.articles (user_id, title, status) values (o, 'qa-sb636 A2', 'draft') returning id into a2;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/m.png', o, a2, 'accepted') returning id into m;
  update public.articles set image_asset_id = m where id = a2;

  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  set local role authenticated;
  -- accept a candidate: the old header is demoted, the article points at the new one
  res := public.set_article_header(a, c1);
  r := r || jsonb_build_object('TC-SB636-01.accept_candidate',
         case when (res->>'demoted')::int = 1
                   and (select status from public.image_assets where id = h0) = 'saved'
                   and (select status from public.image_assets where id = c1) = 'accepted'
                   and (select image_asset_id from public.articles where id = a) = c1
              then 'pass' else 'FAIL: ' || res::text end);
  -- SB-643: reuse a library image: the article gets a copy; the library row is untouched
  res := public.set_article_header(a, lib);
  cp := (res->>'image_id')::uuid;
  r := r || jsonb_build_object('TC-SB643-01.library_image_copied',
         case when cp is not null and cp <> lib and (res->>'copied_from')::uuid = lib
                   and (select status || ':' || coalesce(article_id::text, '') from public.image_assets where id = lib) = 'saved:'
                   and (select status || ':' || article_id || ':' || storage_path || ':' || (meta->>'copied_from') || ':' || description || ':' || user_id
                          from public.image_assets where id = cp) = 'accepted:' || a || ':qa-sb636/lib.png:' || lib || ':qa lib:' || o
                   and (select status from public.image_assets where id = c1) = 'saved'
                   and (select image_asset_id from public.articles where id = a) = cp
                   and (select count(*) from public.image_assets where article_id = a and status = 'accepted') = 1
              then 'pass' else 'FAIL: ' || res::text end);
  snap := (select string_agg(id || status || coalesce(article_id::text, ''), ',' order by id) from public.image_assets where storage_path like 'qa-sb636/%')
          || (select image_asset_id::text from public.articles where id = a);
  -- another user's article or image: not found, nothing changes
  begin perform public.set_article_header(b, c1); st := 'ran'; exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB636-01.other_users_article', case when st = 'P0002' then 'pass' else 'FAIL: ' || st end);
  begin perform public.set_article_header(a, xi); st := 'ran'; exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB636-01.other_users_image', case when st = 'P0002' then 'pass' else 'FAIL: ' || st end);
  begin perform public.set_article_header(a, null); st := 'ran'; exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB636-01.null_refused', case when st = '22004' then 'pass' else 'FAIL: ' || st end);
  r := r || jsonb_build_object('TC-SB636-01.refusals_change_nothing',
         case when snap = (select string_agg(id || status || coalesce(article_id::text, ''), ',' order by id) from public.image_assets where storage_path like 'qa-sb636/%')
                          || (select image_asset_id::text from public.articles where id = a)
              then 'pass' else 'FAIL' end);
  -- the library image whose copy is already the header: no second copy, nothing changes
  res := public.set_article_header(a, lib);
  r := r || jsonb_build_object('TC-SB636-01.same_image_noop',
         case when (res->>'demoted')::int = 0 and (res->>'detached')::int = 0 and (res->>'image_id')::uuid = cp
                   and snap = (select string_agg(id || status || coalesce(article_id::text, ''), ',' order by id) from public.image_assets where storage_path like 'qa-sb636/%')
                              || (select image_asset_id::text from public.articles where id = a)
              then 'pass' else 'FAIL: ' || res::text end);
  -- another article's header moves to A: that article no longer points at it
  res := public.set_article_header(a, m);
  r := r || jsonb_build_object('TC-SB636-01.move_detaches',
         case when (res->>'detached')::int = 1 and (res->>'demoted')::int = 1
                   and (select image_asset_id from public.articles where id = a2) is null
                   and (select image_asset_id from public.articles where id = a) = m
                   and (select status || ':' || article_id from public.image_assets where id = m) = 'accepted:' || a
                   and (select count(*) from public.image_assets where article_id = a and status = 'accepted') = 1
              then 'pass' else 'FAIL: ' || res::text end);
  -- SB-643: the replaced header was a copy: it is rejected, not returned to the library
  r := r || jsonb_build_object('TC-SB643-01.replaced_copy_rejected',
         case when (select status from public.image_assets where id = cp) = 'rejected'
                   and (select status from public.image_assets where id = lib) = 'saved'
                   and (select count(*) from public.image_assets where storage_path = 'qa-sb636/lib.png' and status in ('saved', 'library')) = 1
              then 'pass' else 'FAIL' end);
  -- SB-643: a 'library'-status image is copied too; using the library image again after its copy
  -- was replaced makes a fresh copy
  res := public.set_article_header(a, lib2);
  cp2 := (res->>'image_id')::uuid;
  r := r || jsonb_build_object('TC-SB643-01.library_status_copied',
         case when cp2 <> lib2 and (select status || ':' || coalesce(article_id::text, '') from public.image_assets where id = lib2) = 'library:'
                   and (select image_asset_id from public.articles where id = a) = cp2
                   and (select status from public.image_assets where id = m) = 'saved'
              then 'pass' else 'FAIL: ' || res::text end);
  res := public.set_article_header(a, lib);
  r := r || jsonb_build_object('TC-SB643-01.reuse_after_replace_copies_again',
         case when (res->>'image_id')::uuid not in (cp, lib) and (select status from public.image_assets where id = cp2) = 'rejected'
                   and (select count(*) from public.image_assets where meta->>'copied_from' = lib::text) = 2
                   and (select count(*) from public.image_assets where article_id = a and status = 'accepted') = 1
              then 'pass' else 'FAIL: ' || res::text end);
  reset role;

  -- the database refuses a second accepted image for one article
  begin update public.image_assets set status = 'accepted' where id = c1; st := 'ran'; exception when others then st := sqlstate; end;
  r := r || jsonb_build_object('TC-SB636-01.one_accepted_per_article', case when st = '23505' then 'pass' else 'FAIL: ' || st end);

  -- posture
  r := r || jsonb_build_object('TC-SB636-01.posture',
         case when (select not prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'public.set_article_header(uuid,uuid)'::regprocedure)
                   and not has_function_privilege('anon', 'public.set_article_header(uuid,uuid)', 'execute')
                   and has_function_privilege('authenticated', 'public.set_article_header(uuid,uuid)', 'execute')
              then 'pass' else 'FAIL' end);

  select count(*) into fails from jsonb_each_text(r) where value <> 'pass';
  if fails = 0 then
    raise exception 'ARTICLE_HEADER PASS (% checks): %', (select count(*) from jsonb_object_keys(r)), r::text;
  else
    raise exception 'ARTICLE_HEADER FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r)), r::text;
  end if;
end $suite$;
