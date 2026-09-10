-- SB-409 follow-through: security advisor flagged oauth_client_id() with a role-mutable search_path.
create or replace function public.oauth_client_id()
returns text language sql stable set search_path = ''
as $$ select nullif(auth.jwt() ->> 'client_id', '') $$;;
