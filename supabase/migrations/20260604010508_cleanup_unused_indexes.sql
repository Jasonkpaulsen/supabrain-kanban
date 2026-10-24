-- OPT-005: Clean up unused indexes per Architect directive
-- KEEP: all HNSW embedding indexes (4), GIN tag indexes on high-query tables (agents, decisions, projects)
-- KEEP: all user_id indexes (needed for RLS), all FK indexes, all archived partial indexes on active tables
-- DROP: GIN tag indexes on low-activity tables (conversations, image_assets)
-- DROP: BTREE indexes on tiny/low-value columns

-- GIN tag indexes on low-activity tables (Architect approved drop)
DROP INDEX IF EXISTS idx_conversations_tags;     -- 12 rows, tags never queried via GIN
DROP INDEX IF EXISTS idx_image_assets_tags;       -- 3 rows, tags never queried via GIN

-- BTREE on low-value columns (tiny tables, never used)
DROP INDEX IF EXISTS idx_agents_trigger_type;     -- 13 rows, trigger_type rarely filtered
DROP INDEX IF EXISTS idx_image_assets_type;       -- 3 rows
DROP INDEX IF EXISTS idx_image_assets_archived;   -- 3 rows, partial index on tiny table
DROP INDEX IF EXISTS idx_conversations_archived;  -- 12 rows, partial index on tiny table
DROP INDEX IF EXISTS idx_resume_gen_outcome;      -- 37 rows, outcome rarely filtered

-- Note: keeping all of these per Architect guidance:
-- ✅ 4 HNSW embedding indexes (memories, reference_items, image_assets, skills)
-- ✅ GIN tags on agents, decisions, projects (high-query tables)
-- ✅ 4 GIN career_experiences indexes (capability_tags, technologies, industry, themes — used by resume tailor)
-- ✅ All user_id indexes (RLS performance)
-- ✅ All FK indexes (join performance)
-- ✅ projects_archived, reference_items_archived, decisions_archived (active filtering)
-- ✅ projects_tags, decisions_tags (queried by JARVIS/agents)
-- ✅ idx_work_items_priority, idx_work_items_assigned_agent (kanban board queries);
