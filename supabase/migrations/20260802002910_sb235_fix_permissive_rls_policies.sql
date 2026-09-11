-- SB-235: Fix overly permissive RLS USING(true) on 4 tables (lint 0024)
-- Replace "Select for authenticated" USING(true) with user_id = auth.uid()
-- Service role ALL policies are left intact (service_role needs full access)

-- trade_log
DROP POLICY "Select for authenticated" ON public.trade_log;
CREATE POLICY "Select for authenticated" ON public.trade_log
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- trade_signals
DROP POLICY "Select for authenticated" ON public.trade_signals;
CREATE POLICY "Select for authenticated" ON public.trade_signals
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- weather_obs
DROP POLICY "Select for authenticated" ON public.weather_obs;
CREATE POLICY "Select for authenticated" ON public.weather_obs
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- weather_obs_live
DROP POLICY "Select for authenticated" ON public.weather_obs_live;
CREATE POLICY "Select for authenticated" ON public.weather_obs_live
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());;
