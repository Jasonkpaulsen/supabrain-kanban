
-- Read-only anon access for the PT-1 live dashboard, scoped to the Kalshi (KEL) project + KLAX weather.
-- Low-sensitivity paper-trading/research data only. Drop these policies to revoke.

CREATE POLICY pt1_dashboard_anon_read ON public.trade_log
  FOR SELECT TO anon USING (project_id = 'ef6fdb53-9fd1-4d28-a7b8-d48b00074349');

CREATE POLICY pt1_dashboard_anon_read ON public.trade_signals
  FOR SELECT TO anon USING (project_id = 'ef6fdb53-9fd1-4d28-a7b8-d48b00074349');

CREATE POLICY pt1_dashboard_anon_read ON public.work_items
  FOR SELECT TO anon USING (project_id = 'ef6fdb53-9fd1-4d28-a7b8-d48b00074349');

CREATE POLICY pt1_dashboard_anon_read ON public.work_item_comments
  FOR SELECT TO anon USING (EXISTS (
    SELECT 1 FROM public.work_items w
    WHERE w.id = work_item_comments.work_item_id
      AND w.project_id = 'ef6fdb53-9fd1-4d28-a7b8-d48b00074349'));

CREATE POLICY pt1_dashboard_anon_read ON public.weather_obs
  FOR SELECT TO anon USING (station = 'KLAX');

CREATE POLICY pt1_dashboard_anon_read ON public.weather_obs_live
  FOR SELECT TO anon USING (station = 'KLAX');
;
