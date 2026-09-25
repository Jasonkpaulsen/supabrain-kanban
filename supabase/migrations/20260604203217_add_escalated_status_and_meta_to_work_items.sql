-- Add 'escalated' and 'blocked' to work_items status CHECK constraint
ALTER TABLE public.work_items DROP CONSTRAINT work_items_status_check;
ALTER TABLE public.work_items ADD CONSTRAINT work_items_status_check 
  CHECK (status = ANY (ARRAY['backlog', 'todo', 'in_progress', 'review', 'done', 'escalated', 'blocked']));

-- Add meta jsonb column for structured payloads (escalation data, etc.)
ALTER TABLE public.work_items ADD COLUMN IF NOT EXISTS meta jsonb DEFAULT '{}'::jsonb;

-- Add comment documenting the escalation payload schema
COMMENT ON COLUMN public.work_items.meta IS 'Structured metadata. For escalations (status=escalated): {originating_agent, escalation_chain[], issue_type, context, issue, options_considered[], recommended_action, urgency}';;
