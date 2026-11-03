-- SB-621: 20 RLS policies called auth.uid() once per row (advisor auth_rls_initplan).
--
-- SB-149 introduced the (select auth.uid()) pattern; these 20 predate it (game_vehicle*)
-- or were added after it (20260802002910 on the Kalshi tables). ALTER POLICY rewrites only
-- the expressions: name, command, roles and permissive/restrictive are untouched and no
-- policy is removed. auth.uid() is STABLE, so evaluating it once per statement (an
-- InitPlan) instead of once per row gives the same result.
--
-- The assertion block compares every rewritten expression, with the wrapper taken back
-- out, against a snapshot taken before the change, and then checks that no policy in
-- public still calls auth.<fn>() bare.
create temp table sb621_before as
select c.relname, p.polname, p.polcmd, p.polroles, p.polpermissive,
       pg_get_expr(p.polqual, p.polrelid) q, pg_get_expr(p.polwithcheck, p.polrelid) w
  from pg_policy p join pg_class c on c.oid = p.polrelid
 where c.relnamespace = 'public'::regnamespace
   and (c.relname, p.polname) in (
     ('cip_compliance_matrix', 'cip_compliance_matrix_owner'),
     ('ef_assessments', 'Users can manage their own ef_assessments'),
     ('external_connection_audit_log', 'ecal_insert_self'),
     ('external_connection_audit_log', 'ecal_select_own_or_owner'),
     ('external_connection_limits', 'ecl_select_related'),
     ('game_vehicle_lifestyle_grants', 'Users can insert own grants'),
     ('game_vehicle_upgrades', 'Users can insert own upgrades'),
     ('game_vehicles', 'Users can insert own vehicles'),
     ('governance_audit', 'governance_audit_insert'),
     ('governance_audit', 'governance_audit_select'),
     ('grooming_cadence', 'Users manage own grooming records'),
     ('research_briefs', 'rb_owner_insert'),
     ('research_briefs', 'rb_owner_mark_consumed'),
     ('research_briefs', 'rb_owner_select'),
     ('research_briefs', 'rb_owner_update_draft'),
     ('school_courses', 'school_courses_owner'),
     ('trade_log', 'Select for authenticated'),
     ('trade_signals', 'Select for authenticated'),
     ('weather_obs', 'Select for authenticated'),
     ('weather_obs_live', 'Select for authenticated'));

alter policy cip_compliance_matrix_owner on public.cip_compliance_matrix
  using ((user_id = (select auth.uid())))
  with check ((user_id = (select auth.uid())));
alter policy "Users can manage their own ef_assessments" on public.ef_assessments
  using ((user_id = (select auth.uid())))
  with check ((user_id = (select auth.uid())));
alter policy ecal_insert_self on public.external_connection_audit_log
  with check (((principal_user_id = (select auth.uid())) AND (EXISTS ( SELECT 1
   FROM external_connections c
  WHERE ((c.id = external_connection_audit_log.connection_id) AND (c.principal_user_id = (select auth.uid())))))));
alter policy ecal_select_own_or_owner on public.external_connection_audit_log
  using (((principal_user_id = (select auth.uid())) OR (EXISTS ( SELECT 1
   FROM external_connections c
  WHERE ((c.id = external_connection_audit_log.connection_id) AND (c.created_by = (select auth.uid())))))));
alter policy ecl_select_related on public.external_connection_limits
  using (((connection_id IS NULL) OR (EXISTS ( SELECT 1
   FROM external_connections c
  WHERE ((c.id = external_connection_limits.connection_id) AND ((c.principal_user_id = (select auth.uid())) OR (c.created_by = (select auth.uid()))))))));
alter policy "Users can insert own grants" on public.game_vehicle_lifestyle_grants
  with check (((select auth.uid()) = user_id));
alter policy "Users can insert own upgrades" on public.game_vehicle_upgrades
  with check (((select auth.uid()) = user_id));
alter policy "Users can insert own vehicles" on public.game_vehicles
  with check (((select auth.uid()) = user_id));
alter policy governance_audit_insert on public.governance_audit
  with check ((user_id = (select auth.uid())));
alter policy governance_audit_select on public.governance_audit
  using ((user_id = (select auth.uid())));
alter policy "Users manage own grooming records" on public.grooming_cadence
  using ((project_id IN ( SELECT projects.id
   FROM projects
  WHERE (projects.user_id = (select auth.uid())))));
alter policy rb_owner_insert on public.research_briefs
  with check (((select auth.uid()) = user_id));
alter policy rb_owner_mark_consumed on public.research_briefs
  using ((((select auth.uid()) = user_id) AND (status = 'published'::text)))
  with check ((((select auth.uid()) = user_id) AND (status = ANY (ARRAY['consumed'::text, 'stale'::text]))));
alter policy rb_owner_select on public.research_briefs
  using (((select auth.uid()) = user_id));
alter policy rb_owner_update_draft on public.research_briefs
  using ((((select auth.uid()) = user_id) AND (status = 'draft'::text)))
  with check (((select auth.uid()) = user_id));
alter policy school_courses_owner on public.school_courses
  using (((select auth.uid()) = user_id))
  with check (((select auth.uid()) = user_id));
alter policy "Select for authenticated" on public.trade_log
  using ((user_id = (select auth.uid())));
alter policy "Select for authenticated" on public.trade_signals
  using ((user_id = (select auth.uid())));
alter policy "Select for authenticated" on public.weather_obs
  using ((user_id = (select auth.uid())));
alter policy "Select for authenticated" on public.weather_obs_live
  using ((user_id = (select auth.uid())));

do $assert$
declare n int; bad text;
begin
  if (select count(*) from sb621_before) <> 20 then
    raise exception 'SB-621: expected 20 target policies, found %', (select count(*) from sb621_before);
  end if;
  select count(*), string_agg(b.relname || '.' || b.polname, ', ') into n, bad
    from sb621_before b
    join pg_class c on c.relname = b.relname and c.relnamespace = 'public'::regnamespace
    join pg_policy p on p.polrelid = c.oid and p.polname = b.polname
   where p.polcmd is distinct from b.polcmd
      or p.polroles is distinct from b.polroles
      or p.polpermissive is distinct from b.polpermissive
      or replace(pg_get_expr(p.polqual, p.polrelid), '( SELECT auth.uid() AS uid)', 'auth.uid()') is distinct from b.q
      or replace(pg_get_expr(p.polwithcheck, p.polrelid), '( SELECT auth.uid() AS uid)', 'auth.uid()') is distinct from b.w
      or coalesce(pg_get_expr(p.polqual, p.polrelid), '') || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') not like '%( SELECT auth.uid() AS uid)%';
  if n > 0 then
    raise exception 'SB-621: % policies changed meaning or posture: %', n, bad;
  end if;
  select count(*), string_agg(c.relname || '.' || p.polname, ', ') into n, bad
    from pg_policy p join pg_class c on c.oid = p.polrelid
   where c.relnamespace = 'public'::regnamespace
     and regexp_replace(coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' || coalesce(pg_get_expr(p.polwithcheck, p.polrelid), ''),
                        'SELECT auth\.(uid|jwt|role)\(\) AS (uid|jwt|role)', '', 'g') ~ 'auth\.(uid|jwt|role)\(\)';
  if n > 0 then
    raise exception 'SB-621: % policies in public still call auth.<fn>() per row: %', n, bad;
  end if;
end
$assert$;
