-- Cryptographic origin authentication for mesh-relayed SOS events.
--
-- Context: a mesh relay device may upload an SOS on behalf of a DIFFERENT,
-- possibly-offline origin device — it cannot use the origin's JWT (never
-- transmitted through mesh, by design) to prove whose event this is.
-- Instead, the origin device signs the event locally with a device-bound
-- asymmetric keypair (private key never leaves the device's Keystore/
-- Secure Enclave); the backend verifies that signature against a public
-- key the origin registered during a PRIOR authenticated online session.
--
-- Purely additive: no existing column's meaning changes, and every
-- existing caller of sos_events (which never populated any of the new
-- columns) continues to insert/read exactly as before — the new columns
-- all default to values that reproduce today's behavior
-- (origin_verification_state = 'not_applicable').

-- =============================================================================
-- DEVICE_KEYS: one row per registered signing keypair
-- =============================================================================

-- A "device" here means a signing identity generated once per app
-- install (device_id — a random UUID, never IMEI/MAC/advertising id/phone
-- number, see device_key_service doc comments), NOT a push-token row in
-- `devices` (separate table, separate lifecycle — a device_id can survive
-- push-token churn, and vice versa isn't meaningful). `key_id` (a public
-- key fingerprint) disambiguates key rotation for the same device_id —
-- old keys are never deleted, only revoked, so a past-signed event
-- remains verifiable forever against the exact key that signed it.
CREATE TABLE IF NOT EXISTS device_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id UUID NOT NULL,
  key_id VARCHAR(64) NOT NULL,
  -- SPKI PEM. Not secret — this is the whole point of asymmetric crypto —
  -- but still only ever set by an authenticated registration call, never
  -- client-suppliable for a device_id/key_id the caller doesn't own (see
  -- deviceKeyService.ts's ON CONFLICT ... WHERE ownership check).
  public_key TEXT NOT NULL,
  algorithm VARCHAR(20) NOT NULL DEFAULT 'ECDSA_P256_SHA256',
  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_device_keys_device_key UNIQUE (device_id, key_id)
);
CREATE INDEX IF NOT EXISTS idx_device_keys_user ON device_keys (user_id);
CREATE INDEX IF NOT EXISTS idx_device_keys_device ON device_keys (device_id);

-- =============================================================================
-- SOS_EVENTS: origin authentication columns
-- =============================================================================

-- `user_id` becomes nullable — and ONLY nullable, never defaulted to a
-- claimed-but-unproven identity — for the specific case of a relayed SOS
-- whose origin device has never registered a public key with this
-- backend. Inspected first (per project instruction, before this change):
-- every existing query against sos_events.user_id is already scoped as
-- `WHERE user_id = $1` from an authenticated caller's own id
-- (listSosEvents, updateSosEventStatus, the idempotent-retry lookup) — a
-- NULL row simply never matches any of those and is correctly invisible
-- until reconciliation (see deviceKeyService.reconcilePendingOriginEvents)
-- gives it a real, cryptographically-established owner. No other table
-- joins sos_events assuming user_id is populated (sos_recipients joins on
-- sos_events.id, not user_id). This is deliberately NOT a
-- "claimed-user-id populates user_id provisionally" design — an unverified
-- device must never be treated as cryptographically belonging to anyone.
ALTER TABLE sos_events ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_device_id UUID NULL;
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_key_id VARCHAR(64) NULL;
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_signature TEXT NULL;
-- An unverified, non-authoritative HINT only — a UUID is not a secret, and
-- carrying it lets a future UI say "claims to be from X, unconfirmed"
-- rather than nothing at all. Never used to populate user_id, never used
-- for authorization, never treated as proof of anything (see
-- sosService.ts's createRelayedSosEvent).
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_claimed_user_id UUID NULL REFERENCES users(id) ON DELETE SET NULL;
-- 'not_applicable'  — today's normal path: the authenticated caller IS
--                     the reporter (JWT already proves it), no signature
--                     involved, no behavior change from before this
--                     migration.
-- 'verified'        — a mesh-relayed event whose signature was checked
--                     against a real, active, registered device_keys row.
-- 'unverified_unregistered' — a mesh-relayed event whose claimed origin
--                     device has no registered key (yet). Preserved, never
--                     dropped, never attributed to any account, no
--                     identity-dependent fan-out — see sosService.ts.
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_verification_state VARCHAR(24) NOT NULL DEFAULT 'not_applicable'
  CHECK (origin_verification_state IN ('not_applicable', 'verified', 'unverified_unregistered'));
-- The exact signed field set, verbatim, as originally submitted — the
-- authoritative source for later re-verification (reconciliation), kept
-- byte-identical to what was actually hashed and signed rather than
-- relying on round-tripping through the typed/rounded business columns
-- above (which is a real risk: NUMERIC(9,6) round-tripping is expected to
-- reproduce an identical string here, but the signed bytes should never
-- depend on that expectation holding).
ALTER TABLE sos_events ADD COLUMN IF NOT EXISTS origin_envelope_raw JSONB NULL;

ALTER TABLE sos_events ADD CONSTRAINT chk_sos_events_user_id_verification CHECK (
  (origin_verification_state = 'unverified_unregistered' AND user_id IS NULL)
  OR
  (origin_verification_state != 'unverified_unregistered' AND user_id IS NOT NULL)
);

-- Reconciliation's own lookup shape: "every still-unverified event claiming
-- this origin device". Partial index — the vast majority of rows are
-- 'not_applicable' and would never benefit from this index.
CREATE INDEX IF NOT EXISTS idx_sos_events_origin_pending
  ON sos_events (origin_device_id)
  WHERE origin_verification_state = 'unverified_unregistered';
