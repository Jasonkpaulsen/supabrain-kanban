-- Article header suite: TC-SB636-01 (SB-636).
--
-- Run as postgres. One transaction that always ends by raising, so the fixture articles and
-- images do not survive. Pass = the raised message starts with "ARTICLE_HEADER PASS". The message
-- carries only check names.
--
-- Fixture: O owns article A with an accepted header h0, a candidate c1 and a saved library image
-- lib; X owns article B and image xi.

do $suite$
declare
  r jsonb := '{}'::jsonb; fails int; st text; res jsonb;
  o constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  x constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  a uuid; b uuid; h0 uuid; c1 uuid; lib uuid; xi uuid; snap text;
begin
  insert into public.articles (user_id, title, status) values (o, 'qa-sb636 A', 'draft') returning id into a;
  insert into public.articles (user_id, title, status) values (x, 'qa-sb636 B', 'draft') returning id into b;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/h0.png', o, a, 'accepted') returning id into h0;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/c1.png', o, a, 'candidate') returning id into c1;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/lib.png', o, null, 'saved') returning id into lib;
  insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb636/xi.png', x, b, 'candidate') returning id into xi;
  update public.articles set image_asset_id = h0 where id = a;

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
  -- reuse a library image: it moves to the article as its header
  res := public.set_article_header(a, lib);
  r := r || jsonb_build_object('TC-SB636-01.use_library_image',
         case when (select status || ':' || coalesce(article_id::text, '') from public.image_assets where id = lib) = 'accepted:' || a
                   and (select status from public.image_assets where id = c1) = 'saved'
                   and (select image_asset_id from public.articles where id = a) = lib
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
