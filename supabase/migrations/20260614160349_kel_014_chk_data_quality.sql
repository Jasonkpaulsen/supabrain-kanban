ALTER TABLE trade_signals ADD CONSTRAINT chk_data_quality
CHECK (data_quality IS NULL OR data_quality IN ('insufficient', 'low', 'medium', 'high', 'premium'));;
