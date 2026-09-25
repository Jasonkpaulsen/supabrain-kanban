ALTER TABLE projects DROP CONSTRAINT projects_domain_check;
UPDATE projects SET domain='prediction-markets', updated_at=now() WHERE domain='gambling';
ALTER TABLE projects ADD CONSTRAINT projects_domain_check CHECK (domain = ANY (ARRAY['products','business','career','property','operations','family','hobbies','club','prediction-markets']));;
