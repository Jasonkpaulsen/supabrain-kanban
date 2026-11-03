-- SB-627 (verifier, 2026-10-24): the owner rule must not be forgeable through image_assets.
--
-- 20261024034014 lets a signed-in user see and remove a project-assets object when they own
-- the image_assets row whose storage_path is that object. image_assets let any signed-in user
-- insert a row, or change their own row, with any storage_path, and object names are public
-- (the bucket serves public URLs). So a user could point a row at someone else's file and
-- remove it.
--
-- storage_path and storage_bucket are now set by the service role only: a client (anon or
-- authenticated) may not insert image_assets rows, and may not change those two columns on
-- an update. Nothing needs either: analyze-image inserts the rows with the service-role key,
-- and article-studio only updates status and article_id. A unique (storage_bucket,
-- storage_path) constraint was considered and rejected: analyze-image inserts a new row on
-- each upload, so a re-upload of the same path (lce-image-ingest uses x-upsert) would fail.

create or replace function public.enforce_image_asset_path_service_only()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      raise exception 'SB-627: image_assets rows are created by the service role only'
        using errcode = '42501';
    elsif new.storage_path is distinct from old.storage_path or new.storage_bucket is distinct from old.storage_bucket then
      raise exception 'SB-627: storage_path and storage_bucket are set by the service role only'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$function$;

comment on function public.enforce_image_asset_path_service_only() is
  'SB-627: the project-assets owner rule trusts image_assets.storage_path, so clients may not create rows or move a row''s path.';

revoke all on function public.enforce_image_asset_path_service_only() from public, anon, authenticated;

create trigger trg_image_asset_path_service_only
  before insert or update on public.image_assets
  for each row execute function public.enforce_image_asset_path_service_only();

do $assert$
declare st text; st2 text; st3 text; n int;
  x constant uuid := '5ebab8fc-e993-4aee-bbc1-eb8ff08a2e0e';
  o constant uuid := '5ecbd44a-a3e2-4363-9133-dff3851ba0f5';
  real_path text; own_id uuid;
begin
  select storage_path into real_path from public.image_assets where user_id = o order by created_at limit 1;
  insert into public.image_assets (storage_path, user_id) values ('qa-sb627b/own.png', x) returning id into own_id;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin insert into public.image_assets (storage_path, user_id) values (real_path, x); st := 'inserted';
  exception when others then st := sqlstate; end;
  begin update public.image_assets set storage_path = real_path where id = own_id; st2 := 'updated';
  exception when others then st2 := sqlstate; end;
  begin update public.image_assets set status = 'saved' where id = own_id; get diagnostics n = row_count; st3 := 'updated';
  exception when others then st3 := sqlstate; end;
  reset role;
  if st <> '42501' or st2 <> '42501' or st3 <> 'updated' or n <> 1 then
    raise exception 'SB-627b: insert %, path change %, status change % (% rows)', st, st2, st3, n;
  end if;
  raise exception using errcode = 'P0002', message = 'SB-627b probe done';
exception when sqlstate 'P0002' then null;
end
$assert$;