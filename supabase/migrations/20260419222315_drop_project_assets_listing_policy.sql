
-- Session 5: drop the broad SELECT policy on storage.objects for project-assets.
-- Object URLs continue to resolve via CDN without a listing policy.
-- Skill: tech-supabase-security (rule 9: public buckets do not need broad SELECT)

DROP POLICY IF EXISTS "Public read access" ON storage.objects;
;
