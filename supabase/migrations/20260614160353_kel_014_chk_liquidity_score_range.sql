ALTER TABLE trade_signals ADD CONSTRAINT chk_liquidity_score_range
CHECK (liquidity_score IS NULL OR (liquidity_score >= 0 AND liquidity_score <= 100));;
