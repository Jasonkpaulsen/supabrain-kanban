CREATE TABLE public.trade_signals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid(),
  created_by_agent text,
  -- market identity
  venue text NOT NULL DEFAULT 'kalshi',
  event_ticker text,
  market_ticker text NOT NULL,
  market_title text,
  recommended_side text NOT NULL CHECK (recommended_side IN ('YES','NO')),
  -- pricing & edge
  market_price_cents numeric,            -- current YES price in cents (0-100)
  model_probability numeric CHECK (model_probability >= 0 AND model_probability <= 1),
  edge numeric,                          -- fee-adjusted edge (model_prob - implied), decimal
  kelly_fraction numeric,                -- recommended full Kelly fraction (0-1)
  recommended_size_usd numeric,          -- Kelly-capped suggested stake
  -- composite rating (0-100) + components
  rating integer CHECK (rating >= 0 AND rating <= 100),
  rating_components jsonb DEFAULT '{}'::jsonb,  -- {edge_score, confidence_score, liquidity_score, time_score, agreement_score}
  confidence_label text,                 -- low | medium | high
  data_quality text,                     -- Atlas data-quality label
  liquidity_score numeric,
  -- timing
  close_time timestamptz,
  expires_at timestamptz,                -- signal staleness horizon
  -- compliance gate
  sentinel_cleared boolean NOT NULL DEFAULT false,
  sentinel_verdict text CHECK (sentinel_verdict IN ('CLEAR','CONDITIONAL','BLOCKED')),
  -- provenance
  rationale text,
  sources jsonb DEFAULT '[]'::jsonb,
  -- lifecycle
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN ('proposed','approved','consumed','settled','expired','rejected')),
  consumed_by text,                      -- the external app/client that acted
  consumed_at timestamptz,
  -- outcome / learning loop
  outcome text CHECK (outcome IN ('win','loss','void')),
  outcome_pnl_usd numeric,
  settled_at timestamptz,
  meta jsonb DEFAULT '{}'::jsonb,
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.trade_signals IS 'Kelshe rated trade signals. Agents (Oddsmith) write rated recommendations; an external user-owned app reads CLEARED, high-rating, unconsumed rows and decides execution. Agents never execute — the app does. Lifecycle: proposed -> approved -> consumed -> settled (or expired/rejected).';

ALTER TABLE public.trade_signals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Service role full access" ON public.trade_signals
  FOR ALL USING (true) WITH CHECK (true);

CREATE POLICY "users_select_own" ON public.trade_signals
  FOR SELECT USING (
    ((SELECT auth.uid()) = user_id) OR EXISTS (
      SELECT 1 FROM public.projects p
      JOIN public.project_members pm ON pm.project_id = p.id
      WHERE p.id = trade_signals.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
    )
  );

CREATE POLICY "users_insert_own" ON public.trade_signals
  FOR INSERT WITH CHECK (
    ((SELECT auth.uid()) = user_id) OR EXISTS (
      SELECT 1 FROM public.projects p
      JOIN public.project_members pm ON pm.project_id = p.id
      WHERE p.id = trade_signals.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
        AND pm.role = ANY (ARRAY['owner','editor'])
    )
  );

CREATE POLICY "users_update_own" ON public.trade_signals
  FOR UPDATE USING (
    ((SELECT auth.uid()) = user_id) OR EXISTS (
      SELECT 1 FROM public.projects p
      JOIN public.project_members pm ON pm.project_id = p.id
      WHERE p.id = trade_signals.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
        AND pm.role = ANY (ARRAY['owner','editor'])
    )
  );

CREATE POLICY "users_delete_own" ON public.trade_signals
  FOR DELETE USING ((SELECT auth.uid()) = user_id);

CREATE TRIGGER trigger_update_updated_at BEFORE UPDATE ON public.trade_signals
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE INDEX idx_trade_signals_actionable
  ON public.trade_signals (project_id, status, sentinel_cleared, rating DESC);
CREATE INDEX idx_trade_signals_market ON public.trade_signals (market_ticker);
CREATE INDEX idx_trade_signals_expires ON public.trade_signals (expires_at);;
