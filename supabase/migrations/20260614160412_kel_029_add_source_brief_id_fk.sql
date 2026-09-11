ALTER TABLE trade_signals ADD COLUMN source_brief_id uuid REFERENCES research_briefs(id) ON DELETE SET NULL;;
