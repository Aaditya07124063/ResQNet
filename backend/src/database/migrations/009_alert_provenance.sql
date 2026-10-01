-- Provenance for alerts from external feeds: where exactly the item came
-- from and when ResQNet fetched it. 'international_public' covers public
-- international feeds (e.g. global earthquake catalogues) that are neither
-- a Nepali authority nor a partner, so they are never labelled official.
ALTER TABLE emergency_alerts DROP CONSTRAINT IF EXISTS emergency_alerts_source_type_check;
ALTER TABLE emergency_alerts ADD CONSTRAINT emergency_alerts_source_type_check
  CHECK (source_type IN ('official', 'verified_partner', 'international_public', 'resqnet_system', 'community',
                         'device_sensor'));
ALTER TABLE emergency_alerts ADD COLUMN IF NOT EXISTS source_url VARCHAR(500) NULL
  CHECK (source_url IS NULL OR source_url LIKE 'https://%');
ALTER TABLE emergency_alerts ADD COLUMN IF NOT EXISTS retrieved_at TIMESTAMPTZ NULL;
