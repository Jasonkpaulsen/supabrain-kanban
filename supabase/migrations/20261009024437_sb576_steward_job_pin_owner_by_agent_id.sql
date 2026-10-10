-- SB-576 QA defect D1 (TC-SB576-12): the daily job looked the owner up by agent NAME across all
-- users (it runs as postgres before the role switch, so RLS did not narrow it). Any signed-in user
-- could create an older agent with the same name and silently take over the schedule (the real
-- owner's steward would never run). The job now resolves the owner from the steward agent's own
-- id, which another user cannot forge. Still no literal user id in the job.

select cron.unschedule(jobid) from cron.job where jobname = 'crm-steward-daily';
select cron.schedule('crm-steward-daily', '20 10 * * *', $job$
do $run$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select a.user_id from public.agents a
                               where a.id = '35c61865-2677-42fd-aad3-d2aa8fa81e85'),
                      'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.crm_steward_scheduled('daily');
end $run$;
$job$);

do $chk$
begin
  if not exists (select 1 from cron.job where jobname = 'crm-steward-daily' and active
                   and schedule = '20 10 * * *'
                   and command ~ 'set local role authenticated'
                   and command ~ 'crm_steward_scheduled'
                   and command ~ 'a\.id = ''35c61865-2677-42fd-aad3-d2aa8fa81e85''') then
    raise exception 'A2: the daily job must resolve the owner from the steward agent id and switch role';
  end if;
  if exists (select 1 from cron.job where jobname = 'crm-steward-daily' and command ~ 'a\.name') then
    raise exception 'A4: the daily job must not look the owner up by agent name';
  end if;
  if exists (select 1 from cron.job where command ~* 'crm_steward_run') then
    raise exception 'A3: no cron job may call crm_steward_run directly';
  end if;
end $chk$;
