import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { assertValidP256PublicKey, verifyOriginSignature } from '../utils/originSignature';
import { toDeviceKey, toDeviceKeyRecord, type DbDeviceKeyRow, type DeviceKey, type DeviceKeyRecord } from '../models/DeviceKey';
import type { RegisterDeviceKeyInput } from '../validation/deviceKeySchemas';
import { toSignableOriginFields, type OriginEnvelopeInput } from '../validation/originEnvelopeSchema';
import type { DbSosEventRow } from '../models/SosEvent';
import { runFanOutAndNotify } from './sosFanOutService';

/**
 * Registers (or re-registers, e.g. after key rotation) a device's signing
 * public key. `ON CONFLICT ... WHERE device_keys.user_id = EXCLUDED.user_id`
 * makes re-registration of the SAME (device_id, key_id) idempotent for the
 * SAME account only — a conflict against another user's existing row for
 * that (device_id, key_id) pair is refused (device_id/key_id collision
 * across accounts should be practically impossible given both are
 * randomly generated, but ownership is still checked explicitly rather
 * than assumed).
 *
 * After a successful registration, immediately reconciles any previously
 * stored, unverified mesh SOS events that claimed this exact
 * (device_id, key_id) as their origin — see reconcilePendingOriginEvents.
 * This is the concrete mechanism for "the event can later become verified
 * if the originating device reconnects and registers its public key."
 */
export async function registerDeviceKey(
  userId: string,
  input: RegisterDeviceKeyInput,
): Promise<{ deviceKey: DeviceKey; reconciledEventCount: number }> {
  assertValidP256PublicKey(input.publicKey);

  const { rows } = await pool.query<DbDeviceKeyRow>(
    `INSERT INTO device_keys (user_id, device_id, key_id, public_key, algorithm)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (device_id, key_id) DO UPDATE
       SET revoked_at = NULL
       WHERE device_keys.user_id = EXCLUDED.user_id
     RETURNING *`,
    [userId, input.deviceId, input.keyId, input.publicKey, input.algorithm],
  );
  const row = rows[0];
  if (!row) {
    // The WHERE clause on the DO UPDATE didn't match — this (device_id,
    // key_id) pair already belongs to a different account.
    throw HttpError.conflict('This device key is already registered to a different account');
  }

  let reconciledEventCount = 0;
  try {
    reconciledEventCount = await reconcilePendingOriginEvents(input.deviceId, input.keyId, input.publicKey, userId);
  } catch (err) {
    // Best-effort, same isolation pattern as every other post-write
    // side-effect in this codebase (sosService.ts's fan-out steps) — a
    // reconciliation failure must never fail the registration itself; the
    // event(s) simply stay unverified until the next registration/retry.
    logger.error({ err, deviceId: input.deviceId, keyId: input.keyId }, 'Origin-event reconciliation failed after key registration');
  }

  return { deviceKey: toDeviceKey(row), reconciledEventCount };
}

export async function listDeviceKeys(userId: string): Promise<DeviceKey[]> {
  const { rows } = await pool.query<DbDeviceKeyRow>(
    'SELECT * FROM device_keys WHERE user_id = $1 ORDER BY registered_at DESC',
    [userId],
  );
  return rows.map(toDeviceKey);
}

/**
 * Revokes a device key (compromised/lost/stolen-device handling) —
 * ownership-scoped, same 404-either-way convention as deviceService.ts's
 * deleteDevice. A revoked key's FUTURE signatures are hard-rejected
 * (getActiveDeviceKey below); PAST events already marked 'verified' are
 * NOT retroactively invalidated — a compromise can't be time-traveled,
 * and pretending otherwise would be inventing a guarantee this system
 * cannot actually provide.
 */
export async function revokeDeviceKey(userId: string, deviceId: string): Promise<void> {
  const { rowCount } = await pool.query(
    'UPDATE device_keys SET revoked_at = now() WHERE device_id = $1 AND user_id = $2 AND revoked_at IS NULL',
    [deviceId, userId],
  );
  if (!rowCount) {
    throw HttpError.notFound('Device key not found');
  }
}

/** Internal-only (never exposed through an API response) — the exact row
 * sosService.ts needs to verify a relayed envelope's signature. Returns
 * null for "no such key registered at all" (the unverified-unregistered
 * case), distinct from "registered but revoked" (a hard rejection) —
 * callers must not conflate the two. */
export async function getDeviceKey(deviceId: string, keyId: string): Promise<DeviceKeyRecord | null> {
  const { rows } = await pool.query<DbDeviceKeyRow>(
    'SELECT * FROM device_keys WHERE device_id = $1 AND key_id = $2',
    [deviceId, keyId],
  );
  const row = rows[0];
  return row ? toDeviceKeyRecord(row) : null;
}

/**
 * Re-verifies every sos_events row still marked 'unverified_unregistered'
 * for this exact (device_id, key_id) pair, now that its key has been
 * registered — and, for each one that verifies successfully, backfills
 * `user_id` from THIS registration's authenticated identity and promotes
 * it to 'verified'. A row whose stored signature does NOT verify against
 * this key (a forged claim, or a genuine bit-level corruption) is left
 * exactly as it was — it can never "graduate" without a real matching
 * signature, per the architecture's explicit requirement.
 *
 * Deliberately keyed by (device_id, key_id) together, not device_id
 * alone: registering a DIFFERENT key for the same device_id must never
 * retroactively verify an event signed by a DIFFERENT, still-unregistered
 * key — only re-registering the exact key that originally signed it can.
 */
export async function reconcilePendingOriginEvents(
  deviceId: string,
  keyId: string,
  publicKeyPem: string,
  userId: string,
): Promise<number> {
  const { rows } = await pool.query<DbSosEventRow>(
    `SELECT * FROM sos_events WHERE origin_device_id = $1 AND origin_verification_state = 'unverified_unregistered'`,
    [deviceId],
  );

  let reconciledCount = 0;
  for (const row of rows) {
    if (!row.origin_envelope_raw) continue; // defensive — should always be present in this state
    const envelope = row.origin_envelope_raw as OriginEnvelopeInput;
    if (envelope.keyId !== keyId) continue;

    const valid = verifyOriginSignature(toSignableOriginFields(envelope, row.event_id), row.origin_signature ?? '', publicKeyPem);
    if (!valid) continue;

    const { rows: updatedRows } = await pool.query<DbSosEventRow>(
      `UPDATE sos_events SET user_id = $1, origin_verification_state = 'verified'
       WHERE id = $2 AND origin_verification_state = 'unverified_unregistered'
       RETURNING *`,
      [userId, row.id],
    );
    const updated = updatedRows[0];
    if (!updated) continue; // raced with something else — skip rather than double-process
    reconciledCount++;

    // The identity-dependent fan-out this event never got at creation
    // time (it had no verified owner yet) finally runs now that it does.
    // runFanOutAndNotify lives in its own module specifically so both this
    // service and sosService.ts can depend on it without depending on
    // each other — no circular import.
    try {
      await runFanOutAndNotify(updated, userId);
    } catch (err) {
      logger.error({ err, sosEventId: updated.id }, 'Post-reconciliation fan-out failed — the event is still correctly marked verified');
    }
  }
  return reconciledCount;
}
