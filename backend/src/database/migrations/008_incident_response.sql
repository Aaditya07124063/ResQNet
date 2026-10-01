-- Responder workflow for SOS events. The civilian's own `status` column is
-- untouched; operations progress is tracked separately so a responder can
-- never overwrite what the person in need reported (and vice versa).
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS ops_status VARCHAR(20) NOT NULL DEFAULT 'reported'
  CHECK (ops_status IN ('reported', 'acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'resolved'));
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS assigned_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_sos_events_ops_queue ON sos_events (ops_status, server_received_at DESC);

-- Append-only timeline: who did what, when. Never updated or deleted by
-- the application.
CREATE TABLE IF NOT EXISTS sos_incident_updates (
  id BIGSERIAL PRIMARY KEY,
  sos_event_id UUID NOT NULL REFERENCES sos_events(id) ON DELETE CASCADE,
  employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  action VARCHAR(20) NOT NULL
    CHECK (action IN ('acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'resolved', 'note')),
  assigned_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  note VARCHAR(1000) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sos_incident_updates_event ON sos_incident_updates (sos_event_id, created_at);
