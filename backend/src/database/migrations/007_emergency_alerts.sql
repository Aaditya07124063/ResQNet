-- Emergency alerts shown to the public (app map/alert list) and managed in
-- the emergency operations portal. Every alert states WHERE it came from
-- (source_type + source_name) so a community report or a ResQNet notice can
-- never look like an official government warning.
CREATE TABLE IF NOT EXISTS emergency_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source_type VARCHAR(20) NOT NULL
    CHECK (source_type IN ('official', 'verified_partner', 'resqnet_system', 'community', 'device_sensor')),
  -- Human-readable issuer, e.g. the authority's name or the external feed.
  source_name VARCHAR(160) NOT NULL,
  -- Id in the external feed (for adapter de-duplication); NULL when issued
  -- in the portal.
  external_id VARCHAR(200) NULL,
  category VARCHAR(20) NOT NULL
    CHECK (category IN ('flood', 'earthquake', 'landslide', 'wildfire', 'storm', 'avalanche', 'evacuation',
                        'shelter', 'road_closure', 'health', 'other')),
  severity VARCHAR(12) NOT NULL CHECK (severity IN ('info', 'advisory', 'watch', 'warning', 'emergency')),
  status VARCHAR(12) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved', 'cancelled')),
  title VARCHAR(200) NOT NULL,
  body VARCHAR(4000) NOT NULL,
  instructions VARCHAR(2000) NULL,
  -- Geographic scope: a circle, optionally with named administrative areas.
  latitude DOUBLE PRECISION NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude DOUBLE PRECISION NULL CHECK (longitude BETWEEN -180 AND 180),
  radius_km DOUBLE PRECISION NULL CHECK (radius_km > 0 AND radius_km <= 1000),
  province VARCHAR(80) NULL,
  district VARCHAR(80) NULL,
  municipality VARCHAR(120) NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NULL,
  resolved_at TIMESTAMPTZ NULL,
  created_by_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_emergency_alerts_area CHECK (
    (latitude IS NULL AND longitude IS NULL AND radius_km IS NULL)
    OR (latitude IS NOT NULL AND longitude IS NOT NULL AND radius_km IS NOT NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_emergency_alerts_external
  ON emergency_alerts (source_name, external_id) WHERE external_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emergency_alerts_active ON emergency_alerts (status, expires_at);
CREATE TRIGGER trg_emergency_alerts_updated_at BEFORE UPDATE ON emergency_alerts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
