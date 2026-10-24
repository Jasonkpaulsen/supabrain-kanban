ALTER TABLE research_briefs ADD COLUMN market_category text;

ALTER TABLE research_briefs ADD CONSTRAINT chk_market_category
CHECK (market_category IS NULL OR market_category IN ('economics', 'politics', 'weather', 'climate', 'sports', 'entertainment', 'tech_and_science', 'financials', 'world'));;
