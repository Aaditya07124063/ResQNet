-- Groups (001_init_schema.sql) gain a purpose, so the app can treat a
-- family, a trekking party, or a rescue team differently (e.g. emergency
-- features for 'emergency'/'rescue_team' groups later). Existing rows keep
-- 'general'.
ALTER TABLE groups ADD COLUMN IF NOT EXISTS kind VARCHAR(20) NOT NULL DEFAULT 'general'
  CHECK (kind IN ('general', 'family', 'trekking', 'friends', 'rescue_team', 'organization', 'emergency'));
