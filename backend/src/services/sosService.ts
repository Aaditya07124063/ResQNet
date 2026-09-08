import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { approximateDistanceLabel } from './nearbyAlertService';
import { broadcastSosEvent, runFanOutAndNotify } from './sosFanOutService';
import { getDeviceKey } from './deviceKeyService';
import { verifyOriginSignature } from '../utils/originSignature';
import { toSosEvent, type DbSosEventRow, type SosEvent } from '../models/SosEvent';
import { isDirectSosEventInput, type CreateSosEventInput, type UpdateSosEventStatusInput } from '../validation/sosSchemas';
import { toSignableOriginFields, type OriginEnvelopeInput } from '../validation/originEnvelopeSchema';

interface PgError {
  code?: string;
}

function pgErrorCode(err: unknown): string | undefined {
  return typeof err === 'object' && err !== null ? (err as PgError).code : undefined;
}

/**
 * Creates an SOS event. Two distinct paths, both through this one
 * function and one endpoint (no second SOS system):
 *
 * 1. Direct (today's original behavior, unchanged): `uploaderUserId`
 *    (from the caller's own verified JWT) IS the reporter. No envelope
 *    involved.
 * 2. Relayed (new): `input.originEnvelope` is present — a mesh relay
 *    device, authenticated as ITSELF (`uploaderUserId`), uploading a
 *    cryptographically signed event on behalf of a different, possibly
 *    offline origin device. The uploader's identity is NEVER used as the
 *    event's owner here — see createRelayedSosEvent.
 */
export async function createSosEvent(uploaderUserId: string, input: CreateSosEventInput): Promise<SosEvent> {
  if (input.originEnvelope) {
    return createRelayedSosEvent(input.eventId, input.originEnvelope);
  }
  if (!isDirectSosEventInput(input)) {
    // Unreachable given createSosEventSchema's own superRefine — kept as
    // an explicit, typed error rather than a non-null assertion so the
    // type system's guarantee is actually backed by a runtime check.
    throw HttpError.badRequest('Missing required SOS event fields');
  }

  let row: DbSosEventRow;
  try {
    const { rows } = await pool.query<DbSosEventRow>(
      `INSERT INTO sos_events
         (event_id, user_id, event_source, category, message, latitude, longitude, location_accuracy_m, client_created_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING *`,
      [
        input.eventId,
        uploaderUserId,
        input.eventSource,
        input.category,
        input.message,
        input.latitude,
        input.longitude,
        input.locationAccuracyM,
        input.clientCreatedAt,
      ],
    );
    row = rows[0]!;
  } catch (err) {
    if (pgErrorCode(err) === '23505') {
      // uq_sos_events_event_id — a retried offline send.
      return getExistingDirectEventForRetry(input.eventId, uploaderUserId);
    }
    throw err;
  }

  return runFanOutAndNotify(row, uploaderUserId);
}

/**
 * Records a mesh-relayed, origin-signed SOS event. Never trusts the
 * uploading device's own identity as the event's owner — only a
 * cryptographic match against a registered device_keys row can do that.
 *
 * Three possible outcomes, matching the architecture's explicit
 * requirement not to collapse "received" with "origin verified":
 *
 * - No device_keys row for (originDeviceId, keyId): the origin has never
 *   registered a public key. The event is PRESERVED (never dropped) with
 *   `user_id = NULL` and `origin_verification_state =
 *   'unverified_unregistered'` — it is NOT assigned to any account, and
 *   receives NO identity-dependent fan-out (no self-broadcast, no
 *   trusted-contact push, no nearby push) until/unless the origin device
 *   later registers that exact key (deviceKeyService.reconcilePendingOriginEvents).
 * - Device key found but revoked: hard rejection (403) — a revoked key is
 *   actively distrusted, not merely "not yet known".
 * - Device key found and active, signature verifies: `user_id` is set
 *   from device_keys.user_id (the cryptographically-established owner —
 *   NEVER whatever the uploading device claims), state becomes
 *   'verified', full fan-out runs exactly as the direct path's always has.
 * - Device key found and active, signature does NOT verify: hard
 *   rejection (400) — tampering or spoofing, not a "try again later" case.
 */
async function createRelayedSosEvent(eventId: string, envelope: OriginEnvelopeInput): Promise<SosEvent> {
  if (new Date(envelope.expiresAt).getTime() <= Date.now()) {
    throw HttpError.badRequest('This SOS event has expired');
  }

  const deviceKey = await getDeviceKey(envelope.originDeviceId, envelope.keyId);
  let effectiveUserId: string | null = null;
  let verificationState: 'verified' | 'unverified_unregistered' = 'unverified_unregistered';

  if (deviceKey) {
    if (deviceKey.revokedAt) {
      throw HttpError.forbidden('This origin device key has been revoked');
    }
    const valid = verifyOriginSignature(toSignableOriginFields(envelope, eventId), envelope.signature, deviceKey.publicKey);
    if (!valid) {
      throw HttpError.badRequest('Origin signature verification failed');
    }
    effectiveUserId = deviceKey.userId;
    verificationState = 'verified';
  }

  let row: DbSosEventRow;
  try {
    const { rows } = await pool.query<DbSosEventRow>(
      `INSERT INTO sos_events
         (event_id, user_id, event_source, category, message, latitude, longitude, location_accuracy_m,
          client_created_at, origin_device_id, origin_key_id, origin_signature, origin_claimed_user_id,
          origin_verification_state, origin_envelope_raw)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
       RETURNING *`,
      [
        eventId,
        effectiveUserId,
        envelope.eventSource,
        envelope.category,
        envelope.message,
        envelope.latitude,
        envelope.longitude,
        envelope.locationAccuracyM,
        envelope.createdAt,
        envelope.originDeviceId,
        envelope.keyId,
        envelope.signature,
        envelope.originClaimedUserId,
        verificationState,
        JSON.stringify(envelope),
      ],
    );
    row = rows[0]!;
  } catch (err) {
    if (pgErrorCode(err) === '23505') {
      return getExistingRelayedEventForRetry(eventId, envelope.originDeviceId);
    }
    throw err;
  }

  if (verificationState === 'verified' && effectiveUserId) {
    return runFanOutAndNotify(row, effectiveUserId);
  }

  // Unverified-unregistered: preserved, not attributed, no fan-out.
  return toSosEvent(row);
}

async function getExistingDirectEventForRetry(eventId: string, reporterUserId: string): Promise<SosEvent> {
  const { rows } = await pool.query<DbSosEventRow>('SELECT * FROM sos_events WHERE event_id = $1', [eventId]);
  const existing = rows[0];
  // event_id is unique across ALL users, not just this one — a collision
  // with someone else's event_id must never leak their event back to this
  // caller as if the retry succeeded.
  if (!existing || existing.user_id !== reporterUserId) {
    throw HttpError.conflict('This SOS event id is already in use');
  }
  return toSosEvent(existing);
}

async function getExistingRelayedEventForRetry(eventId: string, originDeviceId: string): Promise<SosEvent> {
  const { rows } = await pool.query<DbSosEventRow>('SELECT * FROM sos_events WHERE event_id = $1', [eventId]);
  const existing = rows[0];
  if (!existing || existing.origin_device_id !== originDeviceId) {
    throw HttpError.conflict('This SOS event id is already in use');
  }
  return toSosEvent(existing);
}

/**
 * The minimum-necessary emergency detail a NEARBY recipient is authorized
 * to see — never the reporter's identity, phone, message, or exact
 * coordinates. Authorization is a real sos_recipients row for this exact
 * (event, user) pair with recipient_category='nearby'; anyone else gets
 * the same 404 as a nonexistent event (IDOR-safe, matches
 * updateSosEventStatus's ownership-scoping convention).
 */
export async function getNearbyEmergencyDetail(
  userId: string,
  sosEventId: string,
): Promise<{
  sosEventId: string;
  category: string;
  status: DbSosEventRow['status'];
  approximateDistance: string;
  activatedAt: string;
}> {
  const { rows } = await pool.query<{
    category: string;
    status: DbSosEventRow['status'];
    server_received_at: Date;
    distance_m: string | null;
  }>(
    `SELECT e.category, e.status, e.server_received_at, r.distance_m
     FROM sos_recipients r
     JOIN sos_events e ON e.id = r.sos_event_id
     WHERE r.sos_event_id = $1 AND r.recipient_user_id = $2 AND r.recipient_category = 'nearby'`,
    [sosEventId, userId],
  );
  const row = rows[0];
  if (!row) {
    throw HttpError.notFound('Emergency not found');
  }
  return {
    sosEventId,
    category: row.category,
    status: row.status,
    approximateDistance: approximateDistanceLabel(row.distance_m !== null ? Number(row.distance_m) : 0),
    activatedAt: row.server_received_at.toISOString(),
  };
}

/** Ownership-scoped, newest first. A relayed event still marked
 * 'unverified_unregistered' has `user_id = NULL`, so it never matches any
 * caller's own id here — correctly invisible until reconciliation gives
 * it a real, verified owner. */
export async function listSosEvents(userId: string): Promise<SosEvent[]> {
  const { rows } = await pool.query<DbSosEventRow>(
    'SELECT * FROM sos_events WHERE user_id = $1 ORDER BY client_created_at DESC',
    [userId],
  );
  return rows.map(toSosEvent);
}

/**
 * Updates an SOS event's status. Ownership-scoped — the same 404 whether
 * the event doesn't exist or belongs to someone else, never revealing
 * which (mirrors trustedContactsService.ts's updateTrustedContact). An
 * unverified-unregistered event (user_id = NULL) can never be updated by
 * anyone through this route until it has a real, verified owner — which
 * is the correct behavior: nobody should be able to acknowledge/resolve
 * an emergency on behalf of an unconfirmed identity.
 */
export async function updateSosEventStatus(
  userId: string,
  sosEventId: string,
  input: UpdateSosEventStatusInput,
): Promise<SosEvent> {
  const isTerminal = input.status === 'resolved' || input.status === 'false_alarm';
  const { rows } = await pool.query<DbSosEventRow>(
    `UPDATE sos_events
     SET status = $1, resolved_at = CASE WHEN $2 THEN now() ELSE resolved_at END
     WHERE id = $3 AND user_id = $4
     RETURNING *`,
    [input.status, isTerminal, sosEventId, userId],
  );
  const row = rows[0];
  if (!row) {
    throw HttpError.notFound('SOS event not found');
  }
  const event = toSosEvent(row);
  broadcastSosEvent('sos_status_updated', userId, event);
  return event;
}
