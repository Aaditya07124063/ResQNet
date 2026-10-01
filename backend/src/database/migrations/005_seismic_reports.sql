-- Hostinger-owned replacement for the former Firestore `seismic_events`
-- collection + `correlateSeismicEvent` Cloud Function (functions/index.js).
-- Devices report local earthquake candidates here; the backend clusters
-- them (seismicService.ts) and alerts other users when enough distinct
-- nearby devices agree.
--
-- Reports are short-lived signals, not a history: rows older than a day
-- are pruned by the service on insert.
CREATE TABLE IF NOT EXISTS seismic_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  latitude DOUBLE PRECISION NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude DOUBLE PRECISION NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  -- On-device detector output — NOT a validated probability.
  detector_score REAL NOT NULL,
  sta_lta_ratio REAL NULL,
  sustained_duration_ms INT NULL,
  oscillation_count INT NULL,
  reported_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_seismic_reports_reported_at ON seismic_reports (reported_at);

-- One corroboration alert per area and time window, so a fourth, fifth, …
-- agreeing device does not trigger another push (the Cloud Function pushed
-- again for every additional device).
CREATE TABLE IF NOT EXISTS seismic_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  device_count INT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_seismic_alerts_created_at ON seismic_alerts (created_at);
