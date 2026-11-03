-- GUARD ADDED 2026-09-20 (SB-439). The body below is otherwise unchanged.
--
-- This migration seeds a row. Replayed into an empty database it would fail on
-- a foreign key: projects.parent_project_id references projects(id) and
-- projects.user_id references auth.users(id), and a branch is created with no
-- data by design.
--
-- Rewritten VALUES -> SELECT ... WHERE, following the pattern this codebase
-- already established in 20260911044338_sb442_family_pm_agent_project_travel_planning:
-- a data migration must not assume production rows exist. On an empty database
-- the guards are false, the SELECT yields no rows, and the migration is a no-op.
--
-- NOT smoke-tested against production, deliberately and unavoidably: the column
-- list includes `depth`, which existed when this migration ran in May and has
-- since been dropped. A historical migration can only be validated by replaying
-- the history that surrounds it, never against today's schema. The column list
-- is therefore left exactly as it was; changing it to suit production would
-- break the replay this guard exists to enable.
INSERT INTO public.projects (name, description, status, priority, tech_stack, repo_urls, links, tags, start_date, meta, parent_project_id, depth, icon, user_id)
SELECT
  'Waterdeep — Dungeon of the Mad Mage Campaign',
  'A campaign workspace for managing the Waterdeep Dungeon of the Mad Mage tabletop RPG campaign. It tracks session preparation, lore, NPCs, locations, tasks, maps, encounters, creative writing, and campaign continuity under the broader RPG Creative Hub.',
  'active',
  'high',
  ARRAY['D&D 5E 2024','Campaign Management','Worldbuilding','Markdown','Supabase','AI-Assisted Writing'],
  ARRAY[]::text[],
  '[]'::jsonb,
  ARRAY['dnd','ttrpg','waterdeep','undermountain','forgotten-realms','campaign-management','worldbuilding','lore'],
  CURRENT_DATE,
  '{"phase":"active-campaign","campaign_module":"Dungeon of the Mad Mage","setting":"Waterdeep and Undermountain","system":"D&D 5E 2024","working_folder":"/RPG/CreativeHub/WaterdeepMadMage","version":"1.0"}'::jsonb,
  '42191e55-f88b-4c76-9efe-21c43f6abb8f',
  1,
  '🏰',
  '5ecbd44a-a3e2-4363-9133-dff3851ba0f5'
WHERE EXISTS (
        SELECT 1 FROM public.projects p
         WHERE p.id = '42191e55-f88b-4c76-9efe-21c43f6abb8f')
  AND EXISTS (
        SELECT 1 FROM auth.users u
         WHERE u.id = '5ecbd44a-a3e2-4363-9133-dff3851ba0f5')
  AND NOT EXISTS (
        SELECT 1 FROM public.projects p2
         WHERE p2.name = 'Waterdeep — Dungeon of the Mad Mage Campaign');
