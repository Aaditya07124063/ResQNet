-- ResQNet backend — initial PostgreSQL schema.
-- Target architecture: Google Sign-In V2 + phone OTP identity, PostgreSQL as
-- the sole application datastore (replaces Firestore), MinIO for object
-- storage (object *references* only live here), a modular email/SMS
-- provider system, and a separate Employee Portal with its own identity
-- space (`employees`, not `users`) for moderation/admin work.
--
-- Deliberately NOT a copy of the Firestore document shapes — see
-- docs/AUDIT.md §R for the source mapping. Run via `npm run migrate`
-- (backend/src/database/migrate.ts). Idempotent (IF NOT EXISTS throughout).
--
-- Design choices worth calling out:
--   * IDs are UUID (gen_random_uuid(), via pgcrypto) everywhere except
--     high-volume append-only logs, which use BIGSERIAL.
--   * Status/role/type fields use VARCHAR + CHECK rather than native
--     Postgres ENUM types, so adding a new value later is a plain
--     ALTER TABLE ... DROP/ADD CONSTRAINT migration instead of the
--     transaction-boundary restrictions native enums impose.
--   * `updated_at` columns are maintained by a shared trigger
--     (set_updated_at()) since Postgres has no ON UPDATE clause.
--   * Employees (staff/moderators) are a completely separate identity
--     space from `users` (consumers) — a compromised consumer account
--     can never escalate into employee-portal access via this schema.
--   * The spec's table list included both "reports" and "user_reports";
--     this schema implements one table (`user_reports`) covering that
--     purpose rather than two near-duplicate tables — see docs/AUDIT.md.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- IDENTITY: users, devices, sessions
-- =============================================================================

-- One row per ResQNet consumer identity. A user may sign in via Google,
-- phone OTP, or (over time) both linked to the same account — hence both
-- identity columns are nullable individually but at least one must be set.
-- Never stores a password (no password auth exists in this system).
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  google_subject VARCHAR(255) NULL,
  email VARCHAR(320) NULL,
  email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  phone_number VARCHAR(32) NULL,
  phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
  display_name VARCHAR(120) NULL,
  account_status VARCHAR(20) NOT NULL DEFAULT 'active'
    CHECK (account_status IN ('active', 'review_required', 'suspended', 'deleted')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_users_google_subject UNIQUE (google_subject),
  CONSTRAINT uq_users_phone_number UNIQUE (phone_number),
  CONSTRAINT chk_users_has_identity CHECK (google_subject IS NOT NULL OR phone_number IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_users_email ON users (email);
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Push-notification-capable devices per user. push_provider is deliberately
-- a free-text column, not a fixed enum — the concrete push provider
-- (FCM/APNs/OneSignal/etc.) is a Phase 17 decision this schema shouldn't
-- pre-commit to.
CREATE TABLE IF NOT EXISTS devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform VARCHAR(10) NOT NULL CHECK (platform IN ('android', 'ios', 'web')),
  push_provider VARCHAR(40) NOT NULL,
  push_token TEXT NOT NULL,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_devices_user_token UNIQUE (user_id, push_token)
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices (user_id);
CREATE TRIGGER trg_devices_updated_at BEFORE UPDATE ON devices
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Refresh-token sessions backing the JWT access+refresh model (H4/Phase 4
-- decision). Only the refresh token's hash is stored — never the raw
-- token — so a database read alone can't be used to impersonate a session.
CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash CHAR(64) NOT NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ NULL,
  user_agent TEXT NULL,
  ip_address INET NULL,
  CONSTRAINT uq_sessions_refresh_token_hash UNIQUE (refresh_token_hash)
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions (expires_at);

-- OTP/verification attempts for both phone and email, replacing what
-- Firebase's verifyPhoneNumber used to own entirely. Only a hash of the
-- code is ever stored. user_id is nullable because verification can happen
-- before an account exists yet (first-time signup).
CREATE TABLE IF NOT EXISTS verification_attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NULL REFERENCES users(id) ON DELETE CASCADE,
  channel VARCHAR(10) NOT NULL CHECK (channel IN ('sms', 'email')),
  target VARCHAR(320) NOT NULL,
  purpose VARCHAR(20) NOT NULL
    CHECK (purpose IN ('login', 'signup', 'phone_verify', 'email_verify', 'account_recovery')),
  code_hash CHAR(64) NOT NULL,
  provider_type VARCHAR(40) NULL,
  attempts INT NOT NULL DEFAULT 0,
  max_attempts INT NOT NULL DEFAULT 5,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ NULL,
  ip_address INET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_verification_target_purpose ON verification_attempts (target, purpose, created_at);
CREATE INDEX IF NOT EXISTS idx_verification_user ON verification_attempts (user_id);

-- =============================================================================
-- PROFILE & TRUSTED CONTACTS
-- =============================================================================

-- 1:1 with users. profile_image_object_key is a MinIO object key, never a
-- public URL — see docs/AUDIT.md §T. Visibility is enforced server-side by
-- the API layer, never assumed from this column alone by any client.
CREATE TABLE IF NOT EXISTS user_profiles (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  father_name VARCHAR(120) NULL,
  age SMALLINT NULL,
  address VARCHAR(300) NULL,
  blood_group VARCHAR(5) NULL,
  allergies TEXT NULL,
  medications TEXT NULL,
  emergency_contact VARCHAR(120) NULL,
  country VARCHAR(80) NULL,
  state VARCHAR(80) NULL,
  city VARCHAR(80) NULL,
  profile_image_object_key TEXT NULL,
  profile_picture_visibility VARCHAR(20) NOT NULL DEFAULT 'private'
    CHECK (profile_picture_visibility IN ('private', 'contacts_only', 'groups_only', 'public')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_user_profiles_updated_at BEFORE UPDATE ON user_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS trusted_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  contact_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,
  name VARCHAR(120) NOT NULL,
  phone_number VARCHAR(32) NOT NULL,
  relationship VARCHAR(60) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_trusted_contacts_owner ON trusted_contacts (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_trusted_contacts_phone ON trusted_contacts (phone_number);
CREATE TRIGGER trg_trusted_contacts_updated_at BEFORE UPDATE ON trusted_contacts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- COMMUNICATE: groups, group_members, conversations, messages
-- =============================================================================

CREATE TABLE IF NOT EXISTS groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name VARCHAR(120) NOT NULL,
  description VARCHAR(500) NULL,
  owner_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  is_protected BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_groups_owner ON groups (owner_user_id);
CREATE TRIGGER trg_groups_updated_at BEFORE UPDATE ON groups
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS group_members (
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role VARCHAR(10) NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'admin', 'member')),
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_group_members_user ON group_members (user_id);

-- A conversation is either a group's chat (type='group', group_id set) or a
-- direct 1:1 chat (type='direct', group_id NULL, participants tracked in
-- conversation_participants). One conversation per group, enforced below.
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type VARCHAR(10) NOT NULL CHECK (type IN ('direct', 'group')),
  group_id UUID NULL REFERENCES groups(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_conversations_group_consistency CHECK (
    (type = 'group' AND group_id IS NOT NULL) OR (type = 'direct' AND group_id IS NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_conversations_group ON conversations (group_id) WHERE group_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS conversation_participants (
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_conversation_participants_user ON conversation_participants (user_id);

-- client_message_id is generated once by the Flutter client (even while
-- offline) so the unique (conversation_id, client_message_id) index makes
-- retried offline sends idempotent — see docs/AUDIT.md §I / the mesh sync
-- requirement. `body` is plain TEXT for now; message encryption-at-rest is
-- flagged as a future hardening item, not implemented in this migration.
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  client_message_id UUID NOT NULL,
  body TEXT NOT NULL,
  attachment_object_key TEXT NULL,
  client_created_at TIMESTAMPTZ NOT NULL,
  server_received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at TIMESTAMPTZ NULL,
  deleted_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_messages_conversation_client_id UNIQUE (conversation_id, client_message_id)
);
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON messages (conversation_id, server_received_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages (sender_user_id);

-- Fan-out audience for a message, fixed at send time (who was a
-- participant when the message was sent — independent of later membership
-- changes). message_status tracks each recipient's evolving delivery/read
-- state against that fixed audience.
CREATE TABLE IF NOT EXISTS message_recipients (
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  recipient_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, recipient_user_id)
);
CREATE INDEX IF NOT EXISTS idx_message_recipients_recipient ON message_recipients (recipient_user_id);

CREATE TABLE IF NOT EXISTS message_status (
  message_id UUID NOT NULL,
  recipient_user_id UUID NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'delivered', 'read')),
  delivered_at TIMESTAMPTZ NULL,
  read_at TIMESTAMPTZ NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, recipient_user_id),
  CONSTRAINT fk_message_status_recipient FOREIGN KEY (message_id, recipient_user_id)
    REFERENCES message_recipients (message_id, recipient_user_id) ON DELETE CASCADE
);
CREATE TRIGGER trg_message_status_updated_at BEFORE UPDATE ON message_status
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- SOS, LOCATIONS, INCIDENTS, OFFICIAL ALERTS
-- =============================================================================

-- event_id is the client-generated idempotency key (retried offline SOS
-- sends must not create duplicates). event_source distinguishes
-- user-initiated SOS from auto-detected crash/earthquake triggers without
-- touching the on-device detectors themselves — they already classify a
-- category/type that the API maps into this column.
CREATE TABLE IF NOT EXISTS sos_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  event_source VARCHAR(20) NOT NULL
    CHECK (event_source IN ('manual', 'crash_detection', 'earthquake_detection')),
  category VARCHAR(40) NOT NULL,
  message TEXT NULL,
  latitude NUMERIC(9, 6) NULL,
  longitude NUMERIC(9, 6) NULL,
  location_accuracy_m NUMERIC(8, 2) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'acknowledged', 'resolved', 'false_alarm')),
  client_created_at TIMESTAMPTZ NOT NULL,
  server_received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_sos_events_event_id UNIQUE (event_id)
);
CREATE INDEX IF NOT EXISTS idx_sos_events_user ON sos_events (user_id);
CREATE INDEX IF NOT EXISTS idx_sos_events_status ON sos_events (status);

-- Fan-out targets for an SOS: a ResQNet user (recipient_user_id) or an
-- external number (recipient_phone_number, e.g. a trusted contact who
-- isn't a ResQNet user, or a hotline) — at least one must be set.
CREATE TABLE IF NOT EXISTS sos_recipients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sos_event_id UUID NOT NULL REFERENCES sos_events(id) ON DELETE CASCADE,
  recipient_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,
  recipient_phone_number VARCHAR(32) NULL,
  channel VARCHAR(10) NOT NULL CHECK (channel IN ('push', 'sms', 'email')),
  status VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  sent_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_sos_recipients_target CHECK (recipient_user_id IS NOT NULL OR recipient_phone_number IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_sos_recipients_event ON sos_recipients (sos_event_id);

-- Minimal-retention location shares tied to a specific sharing context (an
-- SOS event or a group), not an unbounded history table — see
-- docs/AUDIT.md §O.
CREATE TABLE IF NOT EXISTS locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sos_event_id UUID NULL REFERENCES sos_events(id) ON DELETE CASCADE,
  group_id UUID NULL REFERENCES groups(id) ON DELETE CASCADE,
  latitude NUMERIC(9, 6) NOT NULL,
  longitude NUMERIC(9, 6) NOT NULL,
  accuracy_m NUMERIC(8, 2) NULL,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_locations_sos_event ON locations (sos_event_id);
CREATE INDEX IF NOT EXISTS idx_locations_group ON locations (group_id);
CREATE INDEX IF NOT EXISTS idx_locations_user_recorded ON locations (user_id, recorded_at);

-- Broader than a single sos_event: a clustering of related events (e.g.
-- multi-device earthquake corroboration, today's Cloud Function
-- correlateSeismicEvent logic) or a community/official hazard report tied
-- to an area rather than one user.
CREATE TABLE IF NOT EXISTS incidents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  type VARCHAR(40) NOT NULL,
  title VARCHAR(200) NOT NULL,
  description TEXT NULL,
  latitude NUMERIC(9, 6) NULL,
  longitude NUMERIC(9, 6) NULL,
  radius_m NUMERIC(10, 2) NULL,
  severity VARCHAR(10) NOT NULL DEFAULT 'info'
    CHECK (severity IN ('info', 'advisory', 'warning', 'emergency')),
  status VARCHAR(10) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'resolved')),
  origin_sos_event_id UUID NULL REFERENCES sos_events(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_incidents_status ON incidents (status);
CREATE TRIGGER trg_incidents_updated_at BEFORE UPDATE ON incidents
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Strictly separate from sos_events/messages (docs/AUDIT.md §11/§13).
-- issued_by_employee_id references the STAFF identity space, never
-- `users` — a normal authenticated user has no path to populate this
-- table at all; that's enforced at the API/authorization layer, not just
-- by this FK, but the FK's target choice makes a consumer-authored row
-- structurally impossible.
CREATE TABLE IF NOT EXISTS official_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source VARCHAR(80) NOT NULL,
  severity VARCHAR(10) NOT NULL CHECK (severity IN ('info', 'advisory', 'warning', 'emergency')),
  title VARCHAR(200) NOT NULL,
  body TEXT NOT NULL,
  area_country VARCHAR(80) NULL,
  area_state VARCHAR(80) NULL,
  area_city VARCHAR(80) NULL,
  issued_by_employee_id UUID NULL,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NULL
);
CREATE INDEX IF NOT EXISTS idx_official_alerts_area ON official_alerts (area_country, area_state, area_city);
CREATE INDEX IF NOT EXISTS idx_official_alerts_issued_at ON official_alerts (issued_at);

-- =============================================================================
-- EMPLOYEE PORTAL: employees, permissions — separate identity space from users
-- =============================================================================

CREATE TABLE IF NOT EXISTS employees (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(320) NOT NULL,
  password_hash TEXT NOT NULL,
  display_name VARCHAR(120) NOT NULL,
  role VARCHAR(20) NOT NULL DEFAULT 'employee' CHECK (role IN ('super_admin', 'admin', 'employee')),
  status VARCHAR(10) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_employees_email UNIQUE (email)
);
CREATE TRIGGER trg_employees_updated_at BEFORE UPDATE ON employees
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE official_alerts
  ADD CONSTRAINT fk_official_alerts_issuer FOREIGN KEY (issued_by_employee_id)
  REFERENCES employees(id) ON DELETE SET NULL;

-- Granular permissions (USER_VIEW, USER_SUSPEND, MESSAGE_REVIEW, ...) —
-- SUPER_ADMIN is treated as implicitly having every permission by the
-- authorization middleware and does not need rows here; ADMIN/EMPLOYEE
-- only have what's explicitly granted (docs/ARCHITECTURE.md design
-- principle: server derives authorization, nothing is assumed from role
-- name alone beyond SUPER_ADMIN's documented bypass).
CREATE TABLE IF NOT EXISTS employee_permissions (
  employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
  permission VARCHAR(60) NOT NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  PRIMARY KEY (employee_id, permission)
);

-- =============================================================================
-- MODERATION: user_reports, review_cases, moderation_actions, message review
-- =============================================================================

-- A partial unique index prevents the same reporter from stacking multiple
-- OPEN duplicate reports against the same target (docs/AUDIT.md §17's
-- dedup requirement) without blocking a fresh report after the previous
-- one was resolved.
CREATE TABLE IF NOT EXISTS user_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reported_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reason VARCHAR(60) NOT NULL,
  description TEXT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'dismissed', 'actioned')),
  resolution TEXT NULL,
  resolved_by_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  resolved_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_user_reports_not_self CHECK (reporter_user_id <> reported_user_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_reports_open_pair
  ON user_reports (reporter_user_id, reported_user_id) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_user_reports_reported ON user_reports (reported_user_id);

-- One row per "account entered REVIEW_REQUIRED" episode — opened when the
-- admin-configured report threshold is crossed (threshold value itself
-- lives in admin_settings, never hard-coded), closed when an employee
-- resolves it.
CREATE TABLE IF NOT EXISTS review_cases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  target_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status VARCHAR(10) NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  trigger_reason VARCHAR(60) NOT NULL,
  report_count_at_open INT NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at TIMESTAMPTZ NULL,
  closed_by_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_review_cases_target ON review_cases (target_user_id);
CREATE INDEX IF NOT EXISTS idx_review_cases_status ON review_cases (status);

CREATE TABLE IF NOT EXISTS moderation_actions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  target_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  review_case_id UUID NULL REFERENCES review_cases(id) ON DELETE SET NULL,
  action_type VARCHAR(20) NOT NULL
    CHECK (action_type IN ('dismiss', 'warn', 'suspend_temporary', 'suspend_permanent', 'delete', 'escalate')),
  performed_by_employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  reason TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_target ON moderation_actions (target_user_id);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_case ON moderation_actions (review_case_id);

-- General employee-portal action audit (settings changes, provider
-- changes, etc.) — distinct from moderation_actions (user-moderation
-- specific) and from the dedicated message_review_access_log below
-- (message-content access specifically, per the elevated sensitivity
-- called out in docs/AUDIT.md §O).
CREATE TABLE IF NOT EXISTS employee_actions (
  id BIGSERIAL PRIMARY KEY,
  employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  action VARCHAR(80) NOT NULL,
  resource_type VARCHAR(40) NOT NULL,
  resource_id VARCHAR(64) NULL,
  metadata JSONB NULL,
  ip_address INET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_employee_actions_employee ON employee_actions (employee_id);
CREATE INDEX IF NOT EXISTS idx_employee_actions_resource ON employee_actions (resource_type, resource_id);

-- Every time an employee views a reviewed user's last-100-messages, a row
-- goes here. Never stores message content — only the access event itself
-- (who, whom, which case, when, why, how many messages were returned).
CREATE TABLE IF NOT EXISTS message_review_access_log (
  id BIGSERIAL PRIMARY KEY,
  employee_id UUID NOT NULL REFERENCES employees(id) ON DELETE RESTRICT,
  reviewed_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  review_case_id UUID NOT NULL REFERENCES review_cases(id) ON DELETE CASCADE,
  reason TEXT NULL,
  message_count_returned INT NOT NULL,
  accessed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_message_review_log_case ON message_review_access_log (review_case_id);
CREATE INDEX IF NOT EXISTS idx_message_review_log_employee ON message_review_access_log (employee_id);

-- =============================================================================
-- CONFIGURABLE PROVIDERS: email_providers, sms_providers, admin_settings
-- =============================================================================

-- encrypted_credentials holds application-level-encrypted (not just
-- DB-encrypted-at-rest) secret fields (API keys, auth keys, secrets) as an
-- encrypted blob — the encryption key lives only in backend environment
-- config, never in this database. `configuration` holds non-secret,
-- provider-specific settings (sender name, template IDs, route, country,
-- timeout, retry count, ...) as JSONB, matching the "generic provider
-- configuration system" requirement in docs/AUDIT.md §U/§V rather than a
-- fixed column per provider type.
CREATE TABLE IF NOT EXISTS email_providers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_type VARCHAR(40) NOT NULL,
  display_name VARCHAR(120) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  priority INT NOT NULL DEFAULT 100,
  encrypted_credentials BYTEA NOT NULL,
  configuration JSONB NULL,
  last_tested_at TIMESTAMPTZ NULL,
  last_test_status VARCHAR(20) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_email_providers_enabled_priority ON email_providers (enabled, priority);
CREATE TRIGGER trg_email_providers_updated_at BEFORE UPDATE ON email_providers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE IF NOT EXISTS sms_providers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_type VARCHAR(40) NOT NULL,
  display_name VARCHAR(120) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  priority INT NOT NULL DEFAULT 100,
  encrypted_credentials BYTEA NOT NULL,
  configuration JSONB NULL,
  last_tested_at TIMESTAMPTZ NULL,
  last_test_status VARCHAR(20) NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sms_providers_enabled_priority ON sms_providers (enabled, priority);
CREATE TRIGGER trg_sms_providers_updated_at BEFORE UPDATE ON sms_providers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Generic admin-tunable settings (report_threshold, report_window_days,
-- message_review_limit, etc.) as typed key/value rows rather than
-- hard-coded application constants — see docs/PLAN.md Phase 16/22. Seed
-- values are documented in backend/README.md, not auto-inserted here, so a
-- fresh install makes an explicit, reviewed choice rather than inheriting
-- silent defaults from a migration file.
CREATE TABLE IF NOT EXISTS admin_settings (
  key VARCHAR(80) PRIMARY KEY,
  value JSONB NOT NULL,
  description TEXT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL
);
CREATE TRIGGER trg_admin_settings_updated_at BEFORE UPDATE ON admin_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- AUDIT
-- =============================================================================

-- General security/audit trail for consumer- and system-originated events
-- (login, authorization denials, rate-limit hits, SOS creation, etc.) —
-- distinct from employee_actions (employee-portal-specific) and
-- message_review_access_log (message-content-access-specific).
CREATE TABLE IF NOT EXISTS audit_logs (
  id BIGSERIAL PRIMARY KEY,
  actor_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL,
  actor_employee_id UUID NULL REFERENCES employees(id) ON DELETE SET NULL,
  action VARCHAR(80) NOT NULL,
  resource_type VARCHAR(40) NOT NULL,
  resource_id VARCHAR(64) NULL,
  outcome VARCHAR(10) NOT NULL CHECK (outcome IN ('success', 'denied', 'error')),
  metadata JSONB NULL,
  ip_address INET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_user ON audit_logs (actor_user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor_employee ON audit_logs (actor_employee_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_resource ON audit_logs (resource_type, resource_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs (created_at);
