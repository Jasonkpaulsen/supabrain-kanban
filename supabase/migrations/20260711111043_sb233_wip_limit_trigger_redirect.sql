
-- SB-233: Per-assignee WIP-limit trigger (enforce_wip_limit) — REDIRECT approach
-- Spec v2: Redirect to on_hold instead of RAISE EXCEPTION

-- 1. Create wip_limits table for per-assignee overrides
CREATE TABLE IF NOT EXISTS wip_limits (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  assignee TEXT NOT NULL UNIQUE,
  max_wip INTEGER NOT NULL DEFAULT 5,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Seed data: CIP Project Manager grandfather override
INSERT INTO wip_limits (assignee, max_wip)
VALUES ('CIP Project Manager', 6)
ON CONFLICT (assignee) DO NOTHING;

-- 3. Create enforce_wip_limit() function
CREATE OR REPLACE FUNCTION enforce_wip_limit()
RETURNS TRIGGER AS $$
DECLARE
  v_limit INTEGER;
  v_count INTEGER;
  v_ticket_code TEXT;
BEGIN
  -- Only fire on transition INTO in_progress
  IF NEW.status IS DISTINCT FROM 'in_progress' THEN
    RETURN NEW;
  END IF;

  -- For UPDATE, skip if already in_progress (not a transition)
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM 'in_progress' THEN
    RETURN NEW;
  END IF;

  -- Skip if no assignee
  IF NEW.assignee IS NULL THEN
    RETURN NEW;
  END IF;

  -- Exemption: Jason Paulsen (canonical human token per ADR-IDENT-001)
  IF NEW.assignee = 'Jason Paulsen' THEN
    RETURN NEW;
  END IF;

  -- Exemption: wip_override flag
  IF (NEW.meta->>'wip_override') = 'true' THEN
    RETURN NEW;
  END IF;

  -- Resolve limit (priority: wip_limits > agents.max_concurrent_tasks > default 5)
  SELECT wl.max_wip INTO v_limit
  FROM wip_limits wl
  WHERE wl.assignee = NEW.assignee;

  IF v_limit IS NULL THEN
    SELECT a.max_concurrent_tasks INTO v_limit
    FROM agents a
    WHERE a.name = NEW.assignee
      AND a.user_id = NEW.user_id;
  END IF;

  IF v_limit IS NULL THEN
    v_limit := 5;
  END IF;

  -- Count current in_progress items for this assignee (exclude self)
  SELECT COUNT(*) INTO v_count
  FROM work_items
  WHERE user_id = NEW.user_id
    AND assignee = NEW.assignee
    AND status = 'in_progress'
    AND id IS DISTINCT FROM NEW.id;

  -- When at or over limit: REDIRECT to on_hold
  IF v_count >= v_limit THEN
    v_ticket_code := COALESCE(NEW.ticket_code, NEW.id::text);

    -- Redirect status
    NEW.status := 'on_hold';

    -- Tag meta with WIP block details
    NEW.meta := COALESCE(NEW.meta, '{}'::jsonb) || jsonb_build_object(
      'hold_reason', 'wip_limit',
      'wip_blocked_at', now()::text,
      'wip_blocked_assignee', NEW.assignee,
      'wip_blocked_count', v_count,
      'wip_blocked_limit', v_limit
    );

    -- Log to activity_log (action = 'updated' per CHECK constraint)
    BEGIN
      INSERT INTO activity_log (project_id, user_id, agent_name, action, target_table, target_id, summary, meta)
      VALUES (
        NEW.project_id,
        NEW.user_id,
        'System',
        'updated',
        'work_items',
        NEW.id,
        format('WIP limit reached: %s redirected to on_hold. Assignee %s has %s/%s in-progress tickets.',
               v_ticket_code, NEW.assignee, v_count, v_limit),
        jsonb_build_object(
          'trigger', 'enforce_wip_limit',
          'event', 'wip_blocked',
          'ticket_code', v_ticket_code,
          'assignee', NEW.assignee,
          'wip_count', v_count,
          'wip_limit', v_limit
        )
      );
    EXCEPTION WHEN OTHERS THEN
      -- Don't let logging failure block the redirect
      RAISE WARNING 'enforce_wip_limit: activity_log insert failed: %', SQLERRM;
    END;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. Create trigger on work_items
CREATE TRIGGER trg_enforce_wip_limit
  BEFORE INSERT OR UPDATE ON work_items
  FOR EACH ROW
  EXECUTE FUNCTION enforce_wip_limit();
;
