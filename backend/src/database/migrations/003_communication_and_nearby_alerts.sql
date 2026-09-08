-- ResQNet Communication + Nearby Emergency Alert System.
--
-- `conversations` / `conversation_participants` / `messages` /
-- `message_recipients` / `message_status` already exist from
-- 001_init_schema.sql — designed then, never used by any application code
-- until this phase. This migration only adds what that schema was
-- missing for a real V1 (message type / location payload, a race-safe
-- direct-conversation-pair constraint) plus the new nearby-alert tables
-- and an extension to the existing `sos_recipients` fan-out table.
--
-- Every ALTER below is safe against the current schema being genuinely
-- empty (no application code has ever written to `messages` or
-- `conversations`), so no backfill migration is needed for existing rows.

-- =============================================================================
-- MESSAGES: message_type + native location payload
-- =============================================================================

ALTER TABLE messages ADD COLUMN IF NOT EXISTS message_type VARCHAR(20) NOT NULL DEFAULT 'text'
  CHECK (message_type IN ('text', 'location'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS latitude NUMERIC(9, 6) NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS longitude NUMERIC(9, 6) NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS location_accuracy_m NUMERIC(8, 2) NULL;

-- `body` was NOT NULL for the text-only design — a location message has no
-- text body, so this relaxes to nullable and a CHECK enforces the real
-- constraint per type instead (text needs a non-empty body within a size
-- limit; location needs coordinates; a message is never both/neither).
ALTER TABLE messages ALTER COLUMN body DROP NOT NULL;
ALTER TABLE messages ADD CONSTRAINT chk_messages_type_payload CHECK (
  (message_type = 'text' AND body IS NOT NULL AND length(body) BETWEEN 1 AND 4000 AND latitude IS NULL AND longitude IS NULL)
  OR
  (message_type = 'location' AND body IS NULL AND latitude IS NOT NULL AND longitude IS NOT NULL)
);

-- =============================================================================
-- CONVERSATIONS: race-safe direct-pair uniqueness
-- =============================================================================

-- Without this, two concurrent "start a conversation with user X" calls
-- from the same pair of users could each pass a SELECT-finds-nothing check
-- and both INSERT, creating two direct conversations for the same pair.
-- Storing the pair sorted (a < b) on the conversation itself turns
-- find-or-create into a single atomic
-- `INSERT ... ON CONFLICT (direct_user_a_id, direct_user_b_id) DO NOTHING`
-- — the same idempotent-upsert shape already used by
-- userService.findOrCreateUserByGoogleSubject and
-- deviceService.registerDevice.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS direct_user_a_id UUID NULL REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS direct_user_b_id UUID NULL REFERENCES users(id) ON DELETE CASCADE;
ALTER TABLE conversations ADD CONSTRAINT chk_conversations_direct_pair CHECK (
  (type = 'direct' AND direct_user_a_id IS NOT NULL AND direct_user_b_id IS NOT NULL AND direct_user_a_id < direct_user_b_id)
  OR
  (type = 'group' AND direct_user_a_id IS NULL AND direct_user_b_id IS NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_conversations_direct_pair
  ON conversations (direct_user_a_id, direct_user_b_id) WHERE type = 'direct';

-- Cursor pagination over a conversation's own messages, newest first —
-- idx_messages_conversation_created (001_init_schema.sql) already covers
-- this exact (conversation_id, server_received_at) shape.

-- Conversations list ("show me every conversation I'm in, most recent
-- activity first") needs the reverse direction of
-- idx_conversation_participants_user (user -> conversations), then a
-- per-conversation latest-message lookup — covered by
-- idx_messages_conversation_created above (DESC scan per conversation_id).

-- =============================================================================
-- SOS RECIPIENTS: distinguish trusted-contact fan-out from nearby fan-out
-- =============================================================================

-- Existing rows (all created by fanOutToTrustedContacts) are unambiguously
-- trusted-contact fan-out — the DEFAULT backfills them correctly with no
-- separate UPDATE needed.
ALTER TABLE sos_recipients ADD COLUMN IF NOT EXISTS recipient_category VARCHAR(20) NOT NULL DEFAULT 'trusted_contact'
  CHECK (recipient_category IN ('trusted_contact', 'nearby'));
-- Approximate distance at alert time, nearby recipients only — an audit
-- trail for what the recipient was actually told (Section 12: only
-- approximate distance is ever exposed), not a precise re-derivable value.
ALTER TABLE sos_recipients ADD COLUMN IF NOT EXISTS distance_m NUMERIC(10, 2) NULL;
-- A nearby recipient can never be duplicated for the same event (the
-- discovery query already de-dupes per run, but a retried/duplicated
-- discovery call must not double-insert either).
CREATE UNIQUE INDEX IF NOT EXISTS uq_sos_recipients_nearby_unique
  ON sos_recipients (sos_event_id, recipient_user_id)
  WHERE recipient_category = 'nearby' AND recipient_user_id IS NOT NULL;

-- =============================================================================
-- NEARBY EMERGENCY ALERTS: preference + approximate location
-- =============================================================================

-- One row per user. `enabled` defaults to FALSE — nearby alerts are
-- opt-in, not opt-out (Section 12/13: this feature only exists because a
-- user's approximate location can be used to alert them about a stranger's
-- emergency; the safer default for a brand-new capability like that is
-- "off until the user turns it on", not "on until the user notices and
-- turns it off"). `radius_m` is nullable — NULL means "use the server's
-- configured default" (see NEARBY_ALERT_DEFAULT_RADIUS_M in
-- backend/src/config/env.ts), leaving room for a future per-user radius
-- control without a schema change.
CREATE TABLE IF NOT EXISTS nearby_emergency_preferences (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  radius_m INTEGER NULL CHECK (radius_m IS NULL OR radius_m BETWEEN 100 AND 50000),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_nearby_emergency_preferences_updated_at BEFORE UPDATE ON nearby_emergency_preferences
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Approximate last-known location, kept ONLY for users with nearby alerts
-- enabled (enforced at the service layer — disabling the preference
-- deletes this row; see nearbyAlertService.ts). Deliberately not folded
-- into `devices` or `user_profiles`: this is not a durable/precise
-- location history like `locations` (SOS/group location shares) and not a
-- proxy for "where the user lives" like user_profiles' country/state/city
-- — it exists solely to answer "is this user close enough to alert about
-- someone else's SOS right now", and is expected to go stale/unused
-- outside that one purpose.
CREATE TABLE IF NOT EXISTS nearby_alert_locations (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  latitude NUMERIC(9, 6) NOT NULL,
  longitude NUMERIC(9, 6) NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Bounding-box pre-filter indexes (Section 11: PostGIS evaluated and
-- deliberately not introduced — see nearbyAlertService.ts's doc comment
-- for the reasoning). A plain btree range scan on each axis, ANDed
-- together by Postgres's bitmap index scan, keeps nearby-user discovery
-- from ever being an unbounded full-table scan without requiring a new
-- extension.
CREATE INDEX IF NOT EXISTS idx_nearby_alert_locations_lat ON nearby_alert_locations (latitude);
CREATE INDEX IF NOT EXISTS idx_nearby_alert_locations_lng ON nearby_alert_locations (longitude);
