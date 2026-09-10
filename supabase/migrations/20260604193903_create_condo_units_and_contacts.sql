-- condo_units: each physical unit in the building
CREATE TABLE condo_units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  unit TEXT NOT NULL,
  floor INTEGER,
  monthly_maintenance NUMERIC NOT NULL,
  annual_maintenance NUMERIC GENERATED ALWAYS AS (monthly_maintenance * 12) STORED,
  common_interest_pct NUMERIC,
  owner_occupied BOOLEAN DEFAULT false,
  status TEXT DEFAULT 'active' CHECK (status IN ('active', 'sold', 'foreclosure')),
  notes TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  archived BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, unit)
);

CREATE INDEX idx_condo_units_project ON condo_units (project_id);
CREATE TRIGGER trigger_update_updated_at BEFORE UPDATE ON condo_units FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE condo_units ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON condo_units FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON condo_units FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_units.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON condo_units FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_units.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON condo_units FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_units.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON condo_units FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

-- condo_contacts: people associated with each unit
CREATE TABLE condo_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  unit_id UUID NOT NULL REFERENCES condo_units(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'co-owner', 'tenant', 'subtenant', 'emergency_contact', 'board_member', 'vendor', 'representative')),
  first_name TEXT NOT NULL,
  last_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  mailing_address TEXT,
  relationship TEXT,
  is_primary BOOLEAN DEFAULT false,
  move_in_date DATE,
  move_out_date DATE,
  lease_start DATE,
  lease_end DATE,
  monthly_rent NUMERIC,
  notes TEXT,
  meta JSONB DEFAULT '{}'::jsonb,
  archived BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_condo_contacts_unit ON condo_contacts (unit_id);
CREATE INDEX idx_condo_contacts_project ON condo_contacts (project_id);
CREATE INDEX idx_condo_contacts_role ON condo_contacts (role);
CREATE INDEX idx_condo_contacts_current ON condo_contacts (unit_id, role) WHERE archived = false AND move_out_date IS NULL;

CREATE TRIGGER trigger_update_updated_at BEFORE UPDATE ON condo_contacts FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE condo_contacts ENABLE ROW LEVEL SECURITY;
CREATE POLICY service_role_full ON condo_contacts FOR ALL TO service_role USING (true);
CREATE POLICY users_select_own ON condo_contacts FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_contacts.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid())
  ));
CREATE POLICY users_insert_own ON condo_contacts FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_contacts.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_update_own ON condo_contacts FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id OR EXISTS (
    SELECT 1 FROM projects p JOIN project_members pm ON pm.project_id = p.id
    WHERE p.id = condo_contacts.project_id AND p.shared = true AND pm.user_id = (SELECT auth.uid()) AND pm.role IN ('owner', 'editor')
  ));
CREATE POLICY users_delete_own ON condo_contacts FOR DELETE TO authenticated USING ((SELECT auth.uid()) = user_id);

COMMENT ON TABLE condo_units IS '39 Powers LLC condo units — one row per physical unit with maintenance fees and ownership status';
COMMENT ON TABLE condo_contacts IS '39 Powers LLC contacts — owners, co-owners, tenants, emergency contacts per unit. move_out_date IS NULL = current resident';;
