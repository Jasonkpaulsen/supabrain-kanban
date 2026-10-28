-- SB-650 follow-up: give lce_upload_tickets the SB-595 oauth_client_deny policy.
--
-- SB-595's event trigger (oauth_client_default_deny, on CREATE TABLE) adds this restrictive policy to
-- every new public table. It did not fire when 20261028031703 was run in the SQL editor, and that
-- migration's own check asserted "no policies", so the table was created without it and the daily
-- vw_oauth_client_coverage_gaps check reported it on 2026-10-28. No client role can reach the table
-- (no grants), so nothing was exposed; this restores the convention. Same statement as the trigger.
--
-- Note for any future replay: if the event trigger does fire there, it creates this policy during
-- 20261028031703 and that migration's "no policies" assertion fails. Applied history is not edited;
-- a replay is already blocked for other reasons (SB-439), and this note records the second one.

create policy oauth_client_deny on public.lce_upload_tickets as restrictive for all to authenticated
  using ((select public.oauth_client_id()) is null) with check ((select public.oauth_client_id()) is null);

do $$
begin
  if exists (select 1 from public.vw_oauth_client_coverage_gaps where table_name = 'lce_upload_tickets') then
    raise exception 'SB-650: lce_upload_tickets still reported by vw_oauth_client_coverage_gaps';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'lce_upload_tickets'
              and (permissive <> 'RESTRICTIVE' or policyname <> 'oauth_client_deny')) then
    raise exception 'SB-650: lce_upload_tickets must have only the restrictive oauth_client_deny policy';
  end if;
end $$;