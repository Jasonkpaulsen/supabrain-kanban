CREATE TABLE IF NOT EXISTS public.trade_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid REFERENCES public.projects(id) ON DELETE SET NULL,
  user_id uuid DEFAULT '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'::uuid,
  signal_id uuid REFERENCES public.trade_signals(id) ON DELETE SET NULL,
  action text NOT NULL,
  market_ticker text,
  side text,
  count integer,
  price_cents numeric,
  detail text,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.trade_log IS 'Immutable record of execution-engine decisions (dry_run/staged/placed/error). Written by the Kelshe execution engine.';

ALTER TABLE public.trade_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access" ON public.trade_log FOR ALL USING (true) WITH CHECK (true);
CREATE POLICY "users_select_own" ON public.trade_log FOR SELECT
  USING ((SELECT auth.uid()) = user_id);

CREATE INDEX idx_trade_log_created ON public.trade_log (created_at DESC);
CREATE INDEX idx_trade_log_signal ON public.trade_log (signal_id);;
