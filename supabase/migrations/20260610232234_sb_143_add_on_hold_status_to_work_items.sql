-- SB-143: Add on_hold status to work_items
-- Designed by: System Architect (2026-06-10)
-- Impact: Zero downstream — approval gate, move function, kanban view, RLS all unaffected

ALTER TABLE work_items DROP CONSTRAINT work_items_status_check;

ALTER TABLE work_items ADD CONSTRAINT work_items_status_check 
  CHECK (status = ANY (ARRAY['backlog'::text, 'todo'::text, 'in_progress'::text, 'review'::text, 'done'::text, 'escalated'::text, 'blocked'::text, 'on_hold'::text]));;
