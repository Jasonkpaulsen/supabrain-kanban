ALTER TABLE trade_signals ADD CONSTRAINT chk_confidence_label
CHECK (confidence_label IS NULL OR confidence_label IN ('skip', 'speculative', 'moderate', 'high', 'conviction'));;
