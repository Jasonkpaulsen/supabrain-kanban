
-- ============================================================
-- GAME VEHICLES CATALOG
-- Unified schema reconciling both vehicle data source files
-- ============================================================

CREATE TABLE game_vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid(),
  
  -- Identity
  name text NOT NULL,
  category text NOT NULL DEFAULT 'ground',
  description text DEFAULT '',
  notes text DEFAULT '',
  
  -- Core Stats (from complete vehicle list)
  handling int NOT NULL DEFAULT 0,
  passengers text DEFAULT '',
  body int NOT NULL DEFAULT 0,
  device_rating int NOT NULL DEFAULT 0,
  cost int NOT NULL DEFAULT 0,
  
  -- Extended Stats (from framework)
  intelligence int NOT NULL DEFAULT 0,
  hard_points_max int NOT NULL DEFAULT 0,
  armor int NOT NULL DEFAULT 0,
  
  -- Derived Stats (auto-calculated but stored for reference)
  health_max int GENERATED ALWAYS AS (body + 10) STORED,
  resistance int GENERATED ALWAYS AS (device_rating + 3) STORED,
  barrier_rating int GENERATED ALWAYS AS (body) STORED,
  
  -- Collision damage values
  collision_slow int GENERATED ALWAYS AS (body + 2) STORED,
  collision_moderate int GENERATED ALWAYS AS (body + 5) STORED,
  collision_fast int GENERATED ALWAYS AS (body + 10) STORED,
  
  -- Source tracking
  source text NOT NULL DEFAULT 'core_rules',
  is_canonical boolean NOT NULL DEFAULT true,
  
  -- Timestamps
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  
  UNIQUE(project_id, name)
);

-- ============================================================
-- VEHICLE UPGRADES REFERENCE
-- ============================================================

CREATE TABLE game_vehicle_upgrades (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid(),
  
  upgrade_key text NOT NULL,
  display_name text NOT NULL,
  description text DEFAULT '',
  rating_min int DEFAULT 0,
  rating_max int DEFAULT 6,
  cost_formula text NOT NULL,
  notes text DEFAULT '',
  
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  
  UNIQUE(project_id, upgrade_key)
);

-- ============================================================
-- STARTING VEHICLES BY LIFESTYLE
-- ============================================================

CREATE TABLE game_vehicle_lifestyle_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id uuid NOT NULL DEFAULT auth.uid(),
  
  lifestyle text NOT NULL,
  vehicle_name text NOT NULL,
  sort_order int NOT NULL DEFAULT 0,
  
  created_at timestamptz NOT NULL DEFAULT now(),
  
  UNIQUE(project_id, lifestyle, vehicle_name)
);

-- Enable RLS
ALTER TABLE game_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_vehicle_upgrades ENABLE ROW LEVEL SECURITY;
ALTER TABLE game_vehicle_lifestyle_grants ENABLE ROW LEVEL SECURITY;

-- RLS policies
CREATE POLICY "Users can read own vehicles" ON game_vehicles FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own vehicles" ON game_vehicles FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own vehicles" ON game_vehicles FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can read own upgrades" ON game_vehicle_upgrades FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own upgrades" ON game_vehicle_upgrades FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can read own grants" ON game_vehicle_lifestyle_grants FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own grants" ON game_vehicle_lifestyle_grants FOR INSERT WITH CHECK (auth.uid() = user_id);
;
