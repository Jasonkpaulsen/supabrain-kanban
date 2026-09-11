INSERT INTO public.projects (name, description, status, priority, tech_stack, repo_urls, links, tags, start_date, meta, parent_project_id, depth, icon, user_id)
VALUES (
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
);;
