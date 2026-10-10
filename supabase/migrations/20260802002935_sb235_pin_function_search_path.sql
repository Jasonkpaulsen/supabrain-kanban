-- SB-235: Pin function search_path (lint 0011)
--
-- The 6 ticket-listed functions already have search_path=public set:
--   enforce_approval_gate, protect_sentinel_columns, enforce_authority_governance,
--   track_review_entry, escalate_overdue_reviews, enforce_qa_gate
-- (verified via proconfig in audit query — no action needed)
--
-- The 2 watch_ functions flagged by the advisor have NULL proconfig (mutable).
-- They reference unqualified tables (work_items, activity_log) and net.http_post,
-- so they need search_path='public, net'.

ALTER FUNCTION public.watch_cip154_dispatch149() SET search_path = 'public, net';
ALTER FUNCTION public.watch_cip165_dispatch166() SET search_path = 'public, net';;
