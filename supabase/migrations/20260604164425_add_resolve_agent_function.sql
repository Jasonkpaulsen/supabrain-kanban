create or replace function public.resolve_agent(p_name text, p_user_id uuid default null)
returns setof public.agents
language sql stable security invoker
set search_path = public as $$
  select * from public.agents
  where user_id = coalesce(p_user_id, auth.uid())
    and (lower(name) = lower(btrim(p_name))
         or lower(alias) = lower(btrim(p_name)))
  order by (lower(name) = lower(btrim(p_name))) desc
  limit 5;
$$;

comment on function public.resolve_agent(text, uuid) is
  'Resolves an agent by formal name OR alias (case-insensitive) for a given user. Formal-name match takes precedence over alias match. Pass p_user_id when not relying on auth.uid().';;
