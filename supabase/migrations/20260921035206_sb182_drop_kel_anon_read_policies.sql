-- SB-182: remove anonymous read access to the KEL workspace.
--
-- 20260617195117 and 20260617203213 granted the anon role read access to a
-- slice of six tables for a "PT-1 live dashboard": everything belonging to
-- project ef6fdb53 (Kalshi Research & Automation Workspace) plus KLAX weather.
-- Measured as anon with no JWT, that was returning 65 work_items, 20
-- work_item_comments, 20 trade_log rows, 7 experiment_observations, 500
-- weather_obs and 1 weather_obs_live.
--
-- Dropping because:
--   * the KEL project is archived;
--   * trade_signals already refuses anon with 42501 (SB-237 revoked EXECUTE on
--     the is_project_member helper its policy calls), so any dashboard reading
--     the full set is already broken -- this removes a half-working surface,
--     not a working one;
--   * work_items and work_item_comments are the kanban's own tables. The
--     project filter is the only thing that kept the whole board from being
--     anonymously readable, which makes it one predicate away from a much
--     larger exposure than anyone intended.
--
-- 20260617195117 says in its own header "Drop these policies to revoke." This
-- is that. Jason approved on 2026-09-21.
--
-- Reversible: re-create the policies from 20260617195117 / 20260617203213.
-- Nothing else grants anon read on these tables, so after this the anon role
-- can read no application row at all.

drop policy if exists pt1_dashboard_anon_read on public.trade_log;
drop policy if exists pt1_dashboard_anon_read on public.trade_signals;
drop policy if exists pt1_dashboard_anon_read on public.work_items;
drop policy if exists pt1_dashboard_anon_read on public.work_item_comments;
drop policy if exists pt1_dashboard_anon_read on public.weather_obs;
drop policy if exists pt1_dashboard_anon_read on public.weather_obs_live;
drop policy if exists pt1_dashboard_anon_read on public.experiment_observations;

-- Assert the outcome by BEHAVIOUR, as the anon role, not by counting policies
-- (ADR-DL-003 clause 5). A policy can be absent and a row still reachable by
-- some other grant, which is the only question that matters here.
do $$
declare
  r record; n bigint; leaked text := '';
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  for r in
    select unnest(array['trade_log','trade_signals','work_items','work_item_comments',
                        'weather_obs','weather_obs_live','experiment_observations']) as t
  loop
    begin
      execute format('select count(*) from (select 1 from public.%I limit 1) q', r.t) into n;
      if n > 0 then leaked := leaked || ' ' || r.t; end if;
    exception when insufficient_privilege then
      null;   -- a loud refusal is the desired outcome
    end;
  end loop;
  reset role;
  if leaked <> '' then
    raise exception 'SB-182: anon can still read rows from:%', leaked;
  end if;
end $$;
