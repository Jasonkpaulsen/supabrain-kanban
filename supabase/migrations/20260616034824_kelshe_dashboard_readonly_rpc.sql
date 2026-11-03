CREATE OR REPLACE FUNCTION public.kelshe_dashboard()
RETURNS json
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT json_build_object(
    'kpis', (SELECT json_build_object(
        'total', count(*),
        'cleared', count(*) FILTER (WHERE sentinel_cleared),
        'proposed', count(*) FILTER (WHERE status='proposed'),
        'open_positions', count(*) FILTER (WHERE status='consumed')
      ) FROM public.trade_signals WHERE project_id='ef6fdb53-9fd1-4d28-a7b8-d48b00074349'),
    'log_count', (SELECT count(*) FROM public.trade_log),
    'signals', (SELECT coalesce(json_agg(s),'[]'::json) FROM (
        SELECT market_title, market_ticker, recommended_side, rating, market_price_cents,
               edge, recommended_size_usd, confidence_label, status, sentinel_cleared, expires_at
        FROM public.trade_signals
        WHERE project_id='ef6fdb53-9fd1-4d28-a7b8-d48b00074349'
        ORDER BY rating DESC NULLS LAST, created_at DESC LIMIT 30) s),
    'log', (SELECT coalesce(json_agg(l),'[]'::json) FROM (
        SELECT action, market_ticker, side, count, price_cents, detail, created_at
        FROM public.trade_log ORDER BY created_at DESC LIMIT 30) l),
    'generated_at', now()
  );
$$;

REVOKE ALL ON FUNCTION public.kelshe_dashboard() FROM public;
GRANT EXECUTE ON FUNCTION public.kelshe_dashboard() TO anon;
GRANT EXECUTE ON FUNCTION public.kelshe_dashboard() TO authenticated;;
