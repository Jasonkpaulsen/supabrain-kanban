-- Add project_key column
ALTER TABLE projects ADD COLUMN project_key TEXT
  CHECK (project_key ~ '^[A-Z0-9]{2,4}$');

CREATE INDEX idx_projects_project_key ON projects (project_key) WHERE project_key IS NOT NULL;

COMMENT ON COLUMN projects.project_key IS 'Short 2-4 character uppercase code for ticket and test case coding sequences. Sub-projects share parent key. Used in: ticket_code (CIP-001), test_code (CIP-TC-001).';

-- Seed all existing projects with keys
-- CIP family
UPDATE projects SET project_key = 'CIP' WHERE id IN (
  '90811455-9c92-4f72-b52b-42bdff719937',
  '69195421-285a-4aa5-bad7-7006a0372550',
  'f9f53a8e-f9e7-4217-95e3-cee74662d73a',
  'e54db238-8327-4dbc-8b68-9fe269e1d620'
);

-- 39 Powers family
UPDATE projects SET project_key = '39P' WHERE id = 'b39f0000-3900-4000-a000-000039000001';
UPDATE projects SET project_key = 'GOV' WHERE name = 'Board Governance & Secretary';
UPDATE projects SET project_key = 'CMP' WHERE name = 'Compliance & Regulatory';
UPDATE projects SET project_key = 'MNT' WHERE name = 'Maintenance Operations';
UPDATE projects SET project_key = 'TRS' WHERE name = 'Treasury & Finance';

-- SupaBrain Global Operations
UPDATE projects SET project_key = 'SB' WHERE id = 'a07a7f3d-722f-468f-81fa-84e2c5fba704';

-- Open Brain
UPDATE projects SET project_key = 'OB' WHERE id IN (
  'c89d95d1-e61f-4926-84f0-7b41bb581483',
  '974666aa-eccd-4957-afcf-5d2e15eb29cc'
);

-- LinkedIn Content Engine
UPDATE projects SET project_key = 'LCE' WHERE id = '90d800b3-e508-47d7-acc9-56c668f7234f';

-- Job pipeline
UPDATE projects SET project_key = 'JOB' WHERE id IN (
  '219c49e4-9953-41a8-a806-629e7dab00a5',
  'f0c41b99-36ae-4f05-a821-e5a424d8b4e4'
);

-- Resume
UPDATE projects SET project_key = 'RES' WHERE id = '12b404b6-322f-4bec-ab93-34ab9035f63c';

-- BigCat
UPDATE projects SET project_key = 'BC' WHERE id IN (
  'd9a1cd98-2058-45c2-a5fb-6c1b6513fb93',
  '32e6307c-a8e1-4673-8938-32c597c4ddf3',
  'a1b2c3d4-0001-0001-0001-000000000001'
);

-- Paulsen Family
UPDATE projects SET project_key = 'FAM' WHERE id = 'ed8cb7f7-a604-4054-a76e-c3e1114b5316';
UPDATE projects SET project_key = 'FAM' WHERE name IN ('Jason Kurt Paulsen', 'Mandy Marie Paulsen', 'Kai Cyril Paulsen', 'Jai Peter Paulsen', 'Household', 'Holidays & Events');
UPDATE projects SET project_key = 'SYL' WHERE name = 'Sylt Trip 2026';

-- Individual projects
UPDATE projects SET project_key = 'CS' WHERE id = 'a823caba-9416-4bdf-9bc0-86b3066f1e00';
UPDATE projects SET project_key = 'RPG' WHERE id = '42191e55-f88b-4c76-9efe-21c43f6abb8f';
UPDATE projects SET project_key = 'WDM' WHERE id = '3ee51e78-aca7-4409-8c6c-cb9ef5766aaf';
UPDATE projects SET project_key = 'BSC' WHERE id = '1f18ca1f-a9ed-4ddf-a136-0ce8bddeecd5';
UPDATE projects SET project_key = 'DEN' WHERE id = '8f71d126-7449-4fa2-ad1b-fa200cb27029';
UPDATE projects SET project_key = 'JP' WHERE id = 'afeb050b-da26-495e-9442-6edea56efc49';;
