
-- SB-283: Split security_policy_change — add security_hardening_internal (L2)
-- For RLS/auth/grant hardening on internal-infra tables with NO user-data exposure.
-- security_policy_change stays L3+ for changes touching user/family/player data.

-- 1. Insert the new category
INSERT INTO public.authority_action_map (action_category, default_level, escalation_triggers, notes)
VALUES (
  'security_hardening_internal',
  2,
  ARRAY['user_data']::text[],
  'RLS/auth/grant hardening on internal-infra tables with no user-data exposure. Auto-escalates to L3+ via user_data trigger if user/family/player data is involved.'
);

-- 2. Add user_data escalation trigger to security_policy_change so anything
--    touching user/family data auto-escalates regardless of initial category
UPDATE public.authority_action_map
SET escalation_triggers = array_append(escalation_triggers, 'user_data'),
    notes = 'RLS, auth, access policy changes touching user/family/player data. user_data trigger ensures auto-escalation.',
    updated_at = now()
WHERE action_category = 'security_policy_change'
  AND NOT ('user_data' = ANY(escalation_triggers));
;
