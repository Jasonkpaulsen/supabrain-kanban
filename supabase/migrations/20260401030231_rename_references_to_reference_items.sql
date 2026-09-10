
-- Rename table (escaping reserved word)
ALTER TABLE public."references" RENAME TO reference_items;

-- Rename primary key
ALTER INDEX references_pkey RENAME TO reference_items_pkey;

-- Rename indexes
ALTER INDEX idx_references_project RENAME TO idx_reference_items_project;
ALTER INDEX idx_references_type RENAME TO idx_reference_items_type;
ALTER INDEX idx_references_tags RENAME TO idx_reference_items_tags;
ALTER INDEX idx_references_archived RENAME TO idx_reference_items_archived;
ALTER INDEX idx_references_embedding RENAME TO idx_reference_items_embedding;

-- Rename FK constraint
ALTER TABLE public.reference_items RENAME CONSTRAINT references_project_id_fkey TO reference_items_project_id_fkey;

-- Rename CHECK constraint
ALTER TABLE public.reference_items RENAME CONSTRAINT references_type_check TO reference_items_type_check;

-- Rename trigger
ALTER TRIGGER trg_references_updated_at ON public.reference_items RENAME TO trg_reference_items_updated_at;
;
