-- project-assets storage suite: TC-SB627-01 .. TC-SB627-05 (SB-627), TC-SB643-02 (SB-643).
--
-- Run as postgres. One transaction that always ends by raising, so the fixture objects, the
-- image_assets rows and the analyze-image requests their uploads queue do not survive. Pass =
-- the raised message starts with "PROJECT_ASSETS_STORAGE PASS". The message carries only check
-- names and counts.
--
-- Removal is checked through its policy, not by running one: storage.protect_delete refuses
-- direct SQL removals, and the suites write no removal statements. TC-SB627-02 proves the owner
-- rule through SELECT (a Storage API removal reads its rows under the SELECT policies) and pins
-- the removal policy to the same expression.
--
-- Fixture: two objects under qa-sb627/, each with an image_assets row: own.png belongs to O,
-- other.png to X. TC-SB627-05 (verifier, 2026-10-24): X cannot forge an image_assets row, or
-- move their own row's path, to reach O's file. TC-SB643-02: O may add a row for a file O already
-- has a row for (a header copy), and nothing else.

do $suite$
declare
  r jsonb := '{}'::jsonb; n int; n2 int; fails int; st text; st2 text; q0 bigint; q1 bigint; names text[];
  o constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  x constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  own_rule text; real_objects int; other_id uuid; st3 text; st4 text; st5 text; copy_id uuid; ao uuid; xa uuid; st6 text; st7 text; st8 text;
begin
  select count(*) into real_objects from storage.objects where bucket_id = 'project-assets';
  insert into storage.objects (bucket_id, name, metadata) values
    ('project-assets', 'qa-sb627/own.png', '{"mimetype":"image/png"}'),
    ('project-assets', 'qa-sb627/other.png', '{"mimetype":"image/png"}');
  insert into public.image_assets (storage_path, user_id) values ('qa-sb627/own.png', o);
  insert into public.image_assets (storage_path, user_id) values ('qa-sb627/other.png', x) returning id into other_id;
  insert into public.articles (user_id, title, status) values (o, 'qa-sb627 O', 'draft') returning id into ao;
  insert into public.articles (user_id, title, status) values (x, 'qa-sb627 X', 'draft') returning id into xa;

  -- TC-SB627-01: anon writes nothing.
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  begin insert into storage.objects (bucket_id, name) values ('project-assets', 'qa-sb627/anon.png'); st := 'inserted';
  exception when others then st := sqlstate; end;
  update storage.objects set metadata = '{"mimetype":"image/gif"}' where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  get diagnostics n = row_count;
  reset role;
  r := r || jsonb_build_object('TC-SB627-01.anon_cannot_upload', case when st = '42501' then 'pass' else 'FAIL: ' || st end);
  r := r || jsonb_build_object('TC-SB627-01.anon_cannot_update', case when n = 0 then 'pass' else 'FAIL: ' || n || ' rows' end);
  r := r || jsonb_build_object('TC-SB627-01.no_public_or_anon_policy',
         case when not exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
                               and (0::oid = any(polroles) or 'anon'::regrole::oid = any(polroles))) then 'pass' else 'FAIL' end);

  -- TC-SB627-02: a signed-in user cannot upload or update, and sees only their own image files.
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin insert into storage.objects (bucket_id, name, owner_id) values ('project-assets', 'qa-sb627/auth.png', o::text); st := 'inserted';
  exception when others then st := sqlstate; end;
  update storage.objects set metadata = '{"mimetype":"image/gif"}' where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  get diagnostics n = row_count;
  select array_agg(name order by name) into names from storage.objects where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  reset role;
  r := r || jsonb_build_object('TC-SB627-02.user_cannot_upload', case when st = '42501' then 'pass' else 'FAIL: ' || st end);
  r := r || jsonb_build_object('TC-SB627-02.user_cannot_update', case when n = 0 then 'pass' else 'FAIL: ' || n || ' rows' end);
  r := r || jsonb_build_object('TC-SB627-02.owner_sees_own_only',
         case when names = array['qa-sb627/own.png'] then 'pass' else 'FAIL: ' || coalesce(array_to_string(names, ','), 'none') end);
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select array_agg(name order by name) into names from storage.objects where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  select count(*) into n2 from storage.objects where bucket_id = 'project-assets' and name not like 'qa-sb627/%';
  reset role;
  r := r || jsonb_build_object('TC-SB627-02.other_user_sees_own_only',
         case when names = array['qa-sb627/other.png'] and n2 = 0 then 'pass'
              else 'FAIL: ' || coalesce(array_to_string(names, ','), 'none') || ', ' || n2 || ' real' end);
  select pg_get_expr(polqual, polrelid) into own_rule from pg_policy where polrelid = 'storage.objects'::regclass and polname = 'project_assets_select_own';
  r := r || jsonb_build_object('TC-SB627-02.remove_rule_is_owner_rule',
         case when own_rule is not null and strpos(own_rule, '(ia.user_id = ( SELECT auth.uid() AS uid))') > 0
                   and (select pg_get_expr(polqual, polrelid) from pg_policy where polrelid = 'storage.objects'::regclass and polname = 'Allow deletes') = own_rule
                   and (select polroles from pg_policy where polrelid = 'storage.objects'::regclass and polname = 'Allow deletes') = array['authenticated'::regrole]::oid[]
              then 'pass' else 'FAIL' end);

  -- TC-SB627-05: the owner rule cannot be forged through image_assets.
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin insert into public.image_assets (storage_path, user_id) values ('qa-sb627/own.png', x); st := 'inserted';
  exception when others then st := sqlstate; end;
  begin update public.image_assets set storage_path = 'qa-sb627/own.png' where id = other_id; st2 := 'updated';
  exception when others then st2 := sqlstate; end;
  begin update public.image_assets set status = 'saved' where id = other_id; get diagnostics n = row_count; st3 := 'updated';
  exception when others then st3 := sqlstate; end;
  select array_agg(name order by name) into names from storage.objects where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  reset role;
  r := r || jsonb_build_object('TC-SB627-05.no_forged_row', case when st = '42501' then 'pass' else 'FAIL: ' || st end);
  r := r || jsonb_build_object('TC-SB627-05.no_path_move', case when st2 = '42501' then 'pass' else 'FAIL: ' || st2 end);
  r := r || jsonb_build_object('TC-SB627-05.status_edit_still_works', case when st3 = 'updated' and n = 1 then 'pass' else 'FAIL: ' || st3 || ', ' || coalesce(n, 0) end);
  r := r || jsonb_build_object('TC-SB627-05.other_file_still_hidden',
         case when names = array['qa-sb627/other.png'] then 'pass' else 'FAIL: ' || coalesce(array_to_string(names, ','), 'none') end);

  -- TC-SB643-02: a copy of your own image row is allowed; nothing else is.
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin insert into public.image_assets (storage_path, user_id, status) values ('qa-sb627/own.png', o, 'accepted') returning id into copy_id; st := 'inserted';
  exception when others then st := sqlstate; end;
  begin insert into public.image_assets (storage_path, user_id) values ('qa-sb627/new.png', o); st2 := 'inserted';
  exception when others then st2 := sqlstate; end;
  begin insert into public.image_assets (storage_path, user_id) values ('qa-sb627/other.png', o); st3 := 'inserted';
  exception when others then st3 := sqlstate; end;
  begin insert into public.image_assets (storage_path, user_id) values ('qa-sb627/own.png', x); st4 := 'inserted';
  exception when others then st4 := sqlstate; end;
  begin update public.image_assets set storage_path = 'qa-sb627/other.png' where id = copy_id; st5 := 'updated';
  exception when others then st5 := sqlstate; end;
  -- verifier 2026-10-26: a row may be attached only to your own article (INSERT and UPDATE)
  begin insert into public.image_assets (storage_path, user_id, article_id, status) values ('qa-sb627/own.png', o, xa, 'accepted'); st6 := 'inserted';
  exception when others then st6 := sqlstate; end;
  begin update public.image_assets set article_id = xa where id = copy_id; st7 := 'updated';
  exception when others then st7 := sqlstate; end;
  begin update public.image_assets set article_id = ao where id = copy_id; get diagnostics n = row_count; st8 := 'updated';
  exception when others then st8 := sqlstate; end;
  select array_agg(name order by name) into names from storage.objects where bucket_id = 'project-assets' and name like 'qa-sb627/%';
  reset role;
  r := r || jsonb_build_object('TC-SB643-02.copy_of_own_row', case when st = 'inserted' and copy_id is not null then 'pass' else 'FAIL: ' || st end);
  r := r || jsonb_build_object('TC-SB643-02.no_row_for_new_path', case when st2 = '42501' then 'pass' else 'FAIL: ' || st2 end);
  r := r || jsonb_build_object('TC-SB643-02.no_row_for_other_users_path', case when st3 = '42501' then 'pass' else 'FAIL: ' || st3 end);
  r := r || jsonb_build_object('TC-SB643-02.no_copy_for_another_user', case when st4 = '42501' then 'pass' else 'FAIL: ' || st4 end);
  r := r || jsonb_build_object('TC-SB643-02.copy_path_still_fixed', case when st5 = '42501' then 'pass' else 'FAIL: ' || st5 end);
  r := r || jsonb_build_object('TC-SB643-02.no_insert_onto_other_users_article', case when st6 = '42501' then 'pass' else 'FAIL: ' || st6 end);
  r := r || jsonb_build_object('TC-SB643-02.no_move_onto_other_users_article', case when st7 = '42501' then 'pass' else 'FAIL: ' || st7 end);
  r := r || jsonb_build_object('TC-SB643-02.own_article_still_works', case when st8 = 'updated' and n = 1 then 'pass' else 'FAIL: ' || st8 || ', ' || coalesce(n, 0) end);
  r := r || jsonb_build_object('TC-SB643-02.owner_still_sees_own_only',
         case when names = array['qa-sb627/own.png'] then 'pass' else 'FAIL: ' || coalesce(array_to_string(names, ','), 'none') end);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  begin insert into public.image_assets (storage_path, user_id) values ('qa-sb627/own.png', o); st := 'inserted';
  exception when others then st := sqlstate; end;
  reset role;
  r := r || jsonb_build_object('TC-SB643-02.anon_refused', case when st = '42501' then 'pass' else 'FAIL: ' || st end);

  -- TC-SB627-03: the service role still uploads and updates, and an image upload still queues analysis.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select count(*) into q0 from net.http_request_queue;
  set local role service_role;
  begin insert into storage.objects (bucket_id, name, metadata) values ('project-assets', 'qa-sb627/service.png', '{"mimetype":"image/png"}'); st := 'inserted';
  exception when others then st := sqlstate; end;
  begin update storage.objects set metadata = '{"mimetype":"image/png","qa":"sb627"}' where bucket_id = 'project-assets' and name = 'qa-sb627/service.png';
    get diagnostics n = row_count; st2 := 'updated';
  exception when others then st2 := sqlstate; end;
  reset role;
  select count(*) into q1 from net.http_request_queue;
  r := r || jsonb_build_object('TC-SB627-03.service_role_writes',
         case when st = 'inserted' and st2 = 'updated' and n = 1 then 'pass' else 'FAIL: ' || st || ', ' || st2 || ', ' || coalesce(n, 0) end);
  r := r || jsonb_build_object('TC-SB627-03.upload_queues_analysis', case when q1 - q0 = 1 then 'pass' else 'FAIL: queued ' || (q1 - q0) end);

  -- TC-SB627-04: nothing else changed.
  r := r || jsonb_build_object('TC-SB627-04.bucket_unchanged',
         case when (select public and file_size_limit = 10485760 and allowed_mime_types = array['image/jpeg','image/png','image/gif','image/webp','image/svg+xml','application/pdf']
                    from storage.buckets where id = 'project-assets')
                   and real_objects = (select count(*) from storage.objects where bucket_id = 'project-assets' and name not like 'qa-sb627/%')
              then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB627-04.policy_set',
         case when (select string_agg(polname || ':' || polcmd::text || ':' || array_to_string(polroles::regrole[], ','), ' | ' order by polname)
                      from pg_policy where polrelid = 'storage.objects'::regclass)
                   = 'Allow deletes:d:authenticated | Allow updates:w:service_role | Allow uploads:a:service_role | project_assets_select_own:r:authenticated'
              then 'pass' else 'FAIL' end);
  r := r || jsonb_build_object('TC-SB627-04.evidence', format('%s real objects in project-assets', real_objects));

  select count(*) into fails from jsonb_each_text(r) where key not like '%.evidence' and value <> 'pass';
  if fails = 0 then
    raise exception 'PROJECT_ASSETS_STORAGE PASS (% checks): %', (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  else
    raise exception 'PROJECT_ASSETS_STORAGE FAIL (% of % checks): %', fails, (select count(*) from jsonb_object_keys(r) k where k not like '%.evidence'), r::text;
  end if;
end $suite$;
