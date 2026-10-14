
-- Measurement table for PT-1 shadow experiment arms (e.g. center-disagreement watch).
-- Kept separate from trade_log so the paper bankroll ledger stays pure.
CREATE TABLE IF NOT EXISTS public.experiment_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL,
  user_id uuid,
  experiment text NOT NULL,            -- e.g. 'center_disagreement'
  obs_date date NOT NULL,              -- the market target date (event day)
  event_ticker text,
  market_title text,
  model_center_f numeric,              -- corrected model expected high (F)
  market_ev_f numeric,                 -- de-vigged market-implied expected high (F)
  gap_f numeric,                       -- model_center_f - market_ev_f
  model_modal_bucket text,
  market_modal_bucket text,
  threshold_f numeric,
  flagged boolean DEFAULT false,       -- genuine center disagreement (ignores tail artifacts)
  realized_high_f numeric,             -- filled on settlement
  model_closer boolean,                -- on flagged+settled days: was the model closer than the market?
  settled_at timestamptz,
  meta jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (project_id, experiment, obs_date)
);
ALTER TABLE public.experiment_observations ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON public.experiment_observations FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY pt1_dashboard_anon_read ON public.experiment_observations
  FOR SELECT TO anon USING (project_id = 'ef6fdb53-9fd1-4d28-a7b8-d48b00074349');
COMMENT ON TABLE public.experiment_observations IS 'PT-1 shadow-experiment measurements (no bets). One row per experiment+target-date. center_disagreement arm = KEL-056.';
;
