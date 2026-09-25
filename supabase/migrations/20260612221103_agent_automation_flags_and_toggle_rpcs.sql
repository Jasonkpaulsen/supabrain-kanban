-- Per-agent automation flag (Jason-directed, 2026-06-12)
ALTER TABLE agents ADD COLUMN IF NOT EXISTS automation_enabled boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN agents.automation_enabled IS 'Master automation switch for this agent. false = excluded from all scheduled automation (heartbeat, sweeps act-as). Project-level gate is projects.meta.dev_automation; BOTH must be on for dev automation. Toggle via set_agent_automation() RPC.';

-- Front-end friendly toggles (SECURITY INVOKER — RLS applies, user can only touch own rows)
CREATE OR REPLACE FUNCTION set_agent_automation(p_agent_id uuid, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  UPDATE agents SET automation_enabled = p_enabled, updated_at = now()
  WHERE id = p_agent_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'agent not found or not yours'); END IF;
  RETURN jsonb_build_object('ok', true, 'agent', v_name, 'automation_enabled', p_enabled);
END $$;

CREATE OR REPLACE FUNCTION set_project_dev_automation(p_project_id uuid, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_name text;
BEGIN
  UPDATE projects SET meta = COALESCE(meta,'{}'::jsonb) || jsonb_build_object('dev_automation', CASE WHEN p_on THEN 'on' ELSE 'off' END), updated_at = now()
  WHERE id = p_project_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'project not found or not yours'); END IF;
  RETURN jsonb_build_object('ok', true, 'project', v_name, 'dev_automation', CASE WHEN p_on THEN 'on' ELSE 'off' END);
END $$;

REVOKE EXECUTE ON FUNCTION set_agent_automation(uuid, boolean) FROM anon, public;
REVOKE EXECUTE ON FUNCTION set_project_dev_automation(uuid, boolean) FROM anon, public;
GRANT EXECUTE ON FUNCTION set_agent_automation(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION set_project_dev_automation(uuid, boolean) TO authenticated;;
