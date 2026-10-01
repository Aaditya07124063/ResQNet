-- Data lifecycle / retention support (see docs/PRIVACY_AND_RETENTION.md and
-- src/services/retention/). Additive: no data is removed by this migration.

-- ---------------------------------------------------------------------------
-- SOS incidents: the minimum operational record (category, times, states,
-- who acted) has a different lifecycle from the personal data in it
-- (message, exact location, raw signed envelope, delivery phone numbers,
-- responder note text).
-- ---------------------------------------------------------------------------

-- When a responder closed the incident (resolved / stood down). Retention
-- periods count from here, never from creation, so an incident that is
-- still open can never age out.
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS ops_closed_at TIMESTAMPTZ NULL;
UPDATE sos_events e
   SET ops_closed_at = COALESCE(
     (SELECT max(u.created_at) FROM sos_incident_updates u
       WHERE u.sos_event_id = e.id AND u.action IN ('resolved', 'stood_down')),
     e.server_received_at)
 WHERE e.ops_status IN ('resolved', 'stood_down') AND e.ops_closed_at IS NULL;
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_ops_closed_at;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_ops_closed_at
  CHECK ((ops_status IN ('resolved', 'stood_down')) = (ops_closed_at IS NOT NULL));

-- Stage 1: message, exact location, raw envelope and signature removed.
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS sensitive_redacted_at TIMESTAMPTZ NULL;
-- Stage 2: link to the reporter's account and device removed.
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS deidentified_at TIMESTAMPTZ NULL;
-- Migration 004 required user_id on every event that is not waiting for its
-- sender's key. After de-identification (or account deletion, which
-- de-identifies first) the account link is intentionally gone; nothing else
-- may clear it.
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_user_id_verification;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_user_id_verification CHECK (
  (origin_verification_state = 'unverified_unregistered' AND user_id IS NULL)
  OR (origin_verification_state <> 'unverified_unregistered' AND (user_id IS NOT NULL OR deidentified_at IS NOT NULL))
);
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_lifecycle_order;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_lifecycle_order CHECK (
  (sensitive_redacted_at IS NULL OR ops_closed_at IS NOT NULL)
  AND (deidentified_at IS NULL OR sensitive_redacted_at IS NOT NULL)
);
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_redacted_fields;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_redacted_fields CHECK (
  sensitive_redacted_at IS NULL
  OR (message IS NULL AND latitude IS NULL AND longitude IS NULL AND location_accuracy_m IS NULL
      AND origin_envelope_raw IS NULL AND origin_signature IS NULL)
);

-- Retention hold: an operational flag that pauses redaction and
-- de-identification of one incident (e.g. an open investigation). It is not
-- a legal determination. Set/cleared by employees with RETENTION_HOLD_MANAGE.
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS retention_hold_at TIMESTAMPTZ NULL;
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS retention_hold_reason VARCHAR(500) NULL;
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS retention_hold_by_employee_id UUID NULL
  REFERENCES employees(id) ON DELETE RESTRICT;
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_retention_hold;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_retention_hold CHECK (
  (retention_hold_at IS NULL AND retention_hold_reason IS NULL AND retention_hold_by_employee_id IS NULL)
  OR (retention_hold_at IS NOT NULL AND retention_hold_reason IS NOT NULL AND retention_hold_by_employee_id IS NOT NULL)
);

-- Deleting a civilian account must not delete their SOS incidents (before
-- this, ON DELETE CASCADE erased them — including an active emergency —
-- together with the responder timeline). The incident keeps its operational
-- record with no account link; its personal fields follow the normal
-- retention stages, and account deletion redacts them immediately
-- (src/services/accountDeletionService.ts).
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS sos_events_user_id_fkey;
ALTER TABLE sos_events ADD CONSTRAINT sos_events_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL;

-- Responder note text can be redacted while the entry (who, what, when,
-- state change) stays in the timeline.
ALTER TABLE sos_incident_updates ADD COLUMN IF NOT EXISTS note_redacted_at TIMESTAMPTZ NULL;
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS chk_incident_updates_note;
ALTER TABLE sos_incident_updates ADD CONSTRAINT chk_incident_updates_note
  CHECK (action NOT IN ('note', 'stood_down') OR note IS NOT NULL OR note_redacted_at IS NOT NULL);
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS chk_incident_updates_note_redacted;
ALTER TABLE sos_incident_updates ADD CONSTRAINT chk_incident_updates_note_redacted
  CHECK (note_redacted_at IS NULL OR note IS NULL);

-- ---------------------------------------------------------------------------
-- Indexes so each purge batch reads only candidate rows.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sos_events_retention_redact ON sos_events (ops_closed_at)
  WHERE ops_closed_at IS NOT NULL AND sensitive_redacted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_sos_events_retention_deidentify ON sos_events (ops_closed_at)
  WHERE sensitive_redacted_at IS NOT NULL AND deidentified_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_messages_location_age ON messages (server_received_at)
  WHERE latitude IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_deleted_at ON messages (deleted_at) WHERE deleted_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_nearby_alert_locations_updated ON nearby_alert_locations (updated_at);
CREATE INDEX IF NOT EXISTS idx_verification_created ON verification_attempts (created_at);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices (last_seen_at);
CREATE INDEX IF NOT EXISTS idx_device_keys_revoked ON device_keys (revoked_at) WHERE revoked_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_audit_logs_ip_age ON audit_logs (created_at) WHERE ip_address IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_emergency_alerts_closed ON emergency_alerts (updated_at) WHERE status <> 'active';
