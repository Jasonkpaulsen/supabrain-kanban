
-- Link decisions to the conversation they originated from
ALTER TABLE public.decisions
  ADD COLUMN conversation_id UUID REFERENCES public.conversations(id) ON DELETE SET NULL;

-- Index for lookups by conversation
CREATE INDEX idx_decisions_conversation ON public.decisions USING btree (conversation_id);
;
