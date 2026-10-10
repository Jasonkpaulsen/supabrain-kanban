ALTER TABLE job_applications ADD COLUMN posting_date DATE;

COMMENT ON COLUMN job_applications.posting_date IS 'The date the job was originally posted by the company (distinct from discovered_date which is when we found it). Used to track listing freshness and apply age-based scoring decay.';;
