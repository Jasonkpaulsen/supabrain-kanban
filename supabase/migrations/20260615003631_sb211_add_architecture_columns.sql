
-- SB-211: Architecture Decision Persistence Layer — add status, domain, version, supersedes_id

-- 1. Add status column with CHECK constraint
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS status text DEFAULT 'accepted';
ALTER TABLE decisions ADD CONSTRAINT chk_decision_status 
  CHECK (status IN ('proposed','accepted','superseded','deprecated'));

-- 2. Add domain column with 13-domain taxonomy CHECK
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS domain text;
ALTER TABLE decisions ADD CONSTRAINT chk_decision_domain 
  CHECK (domain IN (
    'app_shell','data_layer','ai_runtime','audio_pipeline',
    'security','build_distribution','platform_abstraction',
    'api_integration','ui_ux','testing','monitoring',
    'compliance','infrastructure'
  ));

-- 3. Add version column
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS version integer DEFAULT 1;

-- 4. Add supersedes_id self-referential FK
ALTER TABLE decisions ADD COLUMN IF NOT EXISTS supersedes_id uuid REFERENCES decisions(id);
;
