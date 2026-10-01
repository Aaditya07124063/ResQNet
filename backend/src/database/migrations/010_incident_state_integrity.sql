-- Responder state machine support and database-level integrity for the
-- incident timeline (see src/services/incidentStateMachine.ts).
--
-- Employees are disabled, never deleted, so incident references to them use
-- ON DELETE RESTRICT: history must keep saying who acted and who was
-- assigned, and the CHECKs below could not hold if those were nulled.

-- sos_events: 'stood_down' closes an incident without attending; an
-- incident in an active assignment state must have an assignee.
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS sos_events_ops_status_check;
ALTER TABLE sos_events ADD CONSTRAINT sos_events_ops_status_check
  CHECK (ops_status IN ('reported', 'acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'resolved',
                        'stood_down'));
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS sos_events_assigned_employee_id_fkey;
ALTER TABLE sos_events ADD CONSTRAINT sos_events_assigned_employee_id_fkey
  FOREIGN KEY (assigned_employee_id) REFERENCES employees(id) ON DELETE RESTRICT;
ALTER TABLE sos_events DROP CONSTRAINT IF EXISTS chk_sos_events_active_assignment;
ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_active_assignment
  CHECK (ops_status NOT IN ('assigned', 'en_route', 'arrived', 'assisting') OR assigned_employee_id IS NOT NULL);

-- sos_incident_updates: state before/after each entry and the actor's role
-- at the time. Rows written before this migration keep NULLs there.
ALTER TABLE sos_incident_updates ADD COLUMN IF NOT EXISTS previous_state VARCHAR(20) NULL;
ALTER TABLE sos_incident_updates ADD COLUMN IF NOT EXISTS new_state VARCHAR(20) NULL;
ALTER TABLE sos_incident_updates ADD COLUMN IF NOT EXISTS actor_role VARCHAR(20) NULL;

-- 'civilian_state' records the reporter marking themselves safe / cancelling
-- (previous_state/new_state are then civilian states: active/safe/cancelled).
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS sos_incident_updates_action_check;
ALTER TABLE sos_incident_updates ADD CONSTRAINT sos_incident_updates_action_check
  CHECK (action IN ('acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'resolved', 'stood_down', 'note',
                    'civilian_state'));

ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS sos_incident_updates_employee_id_fkey;
ALTER TABLE sos_incident_updates ADD CONSTRAINT sos_incident_updates_employee_id_fkey
  FOREIGN KEY (employee_id) REFERENCES employees(id) ON DELETE RESTRICT;
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS sos_incident_updates_assigned_employee_id_fkey;
ALTER TABLE sos_incident_updates ADD CONSTRAINT sos_incident_updates_assigned_employee_id_fkey
  FOREIGN KEY (assigned_employee_id) REFERENCES employees(id) ON DELETE RESTRICT;

-- An 'assigned' entry names the assignee; no other entry carries one.
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS chk_incident_updates_assignee;
ALTER TABLE sos_incident_updates ADD CONSTRAINT chk_incident_updates_assignee
  CHECK ((action = 'assigned') = (assigned_employee_id IS NOT NULL));
-- Responder entries have an employee; civilian entries never do.
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS chk_incident_updates_actor;
ALTER TABLE sos_incident_updates ADD CONSTRAINT chk_incident_updates_actor
  CHECK ((action = 'civilian_state') = (employee_id IS NULL));
-- Notes and stand-downs must say something.
ALTER TABLE sos_incident_updates DROP CONSTRAINT IF EXISTS chk_incident_updates_note;
ALTER TABLE sos_incident_updates ADD CONSTRAINT chk_incident_updates_note
  CHECK (action NOT IN ('note', 'stood_down') OR note IS NOT NULL);

CREATE INDEX IF NOT EXISTS idx_sos_events_ops_page ON sos_events (server_received_at DESC, id DESC);
