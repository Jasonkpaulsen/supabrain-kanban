CREATE TABLE IF NOT EXISTS public.weather_obs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid DEFAULT '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'::uuid,
  station text NOT NULL,
  obs_date date NOT NULL,
  tmax_f numeric,
  source text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (station, obs_date)
);
COMMENT ON TABLE public.weather_obs IS 'Historical daily station observations (settlement-grade truth) for MOS bias correction. e.g. KLAX TMAX from NCEI GHCN-Daily. KEL-038.';

CREATE TABLE IF NOT EXISTS public.weather_obs_live (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid DEFAULT '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'::uuid,
  station text NOT NULL,
  ts timestamptz NOT NULL,
  temp_f numeric,
  running_max_f numeric,
  source text,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.weather_obs_live IS 'Live intraday station observations + running daily max for same-day nowcasting. KEL-042.';
CREATE INDEX IF NOT EXISTS idx_weather_obs_live_station_ts ON public.weather_obs_live (station, ts DESC);

ALTER TABLE public.weather_obs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weather_obs_live ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Service role full access" ON public.weather_obs FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "users_select_own_obs" ON public.weather_obs FOR SELECT USING ((SELECT auth.uid()) = user_id);
CREATE POLICY "Service role full access live" ON public.weather_obs_live FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "users_select_own_live" ON public.weather_obs_live FOR SELECT USING ((SELECT auth.uid()) = user_id);;
