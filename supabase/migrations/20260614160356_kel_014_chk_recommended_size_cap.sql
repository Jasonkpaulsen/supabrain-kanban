ALTER TABLE trade_signals ADD CONSTRAINT chk_recommended_size_cap
CHECK (recommended_size_usd IS NULL OR recommended_size_usd <= 500);;
