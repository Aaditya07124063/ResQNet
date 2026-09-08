import { z } from 'zod';
import type { SignableOriginFields } from '../utils/originSignature';

// Fixed-decimal-string patterns matching the precision the origin device
// is expected to sign (and matching sos_events' own NUMERIC(9,6)/(8,2)
// column precision) — see utils/originSignature.ts's doc comment for why
// these travel as exact strings rather than numbers.
const decimalDegreesPattern = /^-?\d{1,3}\.\d{6}$/;
const accuracyPattern = /^\d{1,6}\.\d{2}$/;

/**
 * A cryptographically signed SOS envelope, as produced by the ORIGIN
 * device and carried unmodified through however many mesh relay hops
 * before reaching a device with internet. `keyId` + `signature` let the
 * backend verify this was really signed by a specific registered
 * device_keys row, without ever seeing the origin's JWT/session (never
 * transmitted through mesh, by design).
 */
export const originEnvelopeSchema = z.object({
  protocolVersion: z.literal('1'),
  originDeviceId: z.string().uuid(),
  eventType: z.literal('sos'),
  eventSource: z.enum(['manual', 'crash_detection', 'earthquake_detection']),
  category: z.string().trim().min(1).max(40),
  message: z
    .string()
    .trim()
    .max(2000)
    .nullable()
    .optional()
    .transform((v) => (v ? v : null)),
  latitude: z
    .string()
    .regex(decimalDegreesPattern)
    .nullable()
    .optional()
    .transform((v) => v ?? null),
  longitude: z
    .string()
    .regex(decimalDegreesPattern)
    .nullable()
    .optional()
    .transform((v) => v ?? null),
  locationAccuracyM: z
    .string()
    .regex(accuracyPattern)
    .nullable()
    .optional()
    .transform((v) => v ?? null),
  createdAt: z.string().datetime({ offset: true }),
  expiresAt: z.string().datetime({ offset: true }),
  maxHops: z.number().int().min(1).max(20),
  priority: z.enum(['critical', 'high', 'normal']),
  // An unverified, non-authoritative hint only — see the migration's own
  // doc comment on sos_events.origin_claimed_user_id. A UUID is not a
  // secret; carrying it costs nothing and enables a future "claims to be
  // from X, unconfirmed" UI, but it is NEVER used to populate user_id or
  // for any authorization decision.
  originClaimedUserId: z
    .string()
    .uuid()
    .nullable()
    .optional()
    .transform((v) => v ?? null),
  keyId: z.string().min(1).max(64),
  // Base64. A DER-encoded ECDSA P-256 signature is at most ~72 raw bytes
  // (~100 base64 chars) — 2000 is a generous ceiling, not a real budget,
  // consistent with this project's "reject oversized input outright"
  // convention (see app.ts's JSON body-size comment).
  signature: z.string().min(1).max(2000),
});
export type OriginEnvelopeInput = z.infer<typeof originEnvelopeSchema>;

/** Both latitude and longitude present, or neither — matches the direct
 * (non-relayed) sos schema's own implicit invariant, enforced explicitly
 * here since the two fields are independently optional in the shape
 * above. */
export function originEnvelopeHasConsistentCoordinates(envelope: OriginEnvelopeInput): boolean {
  return (envelope.latitude === null) === (envelope.longitude === null);
}

/**
 * Maps a validated envelope (plus the request's own top-level `eventId` —
 * not part of the envelope itself, see the schema's own doc comment) onto
 * the exact field set that gets signed/verified. The single, shared
 * source of this mapping — sosService.ts (initial creation) and
 * deviceKeyService.ts (reconciliation after a later key registration)
 * both call this rather than each maintaining their own copy, so the two
 * can never silently drift apart.
 */
export function toSignableOriginFields(envelope: OriginEnvelopeInput, eventId: string): SignableOriginFields {
  return {
    protocolVersion: envelope.protocolVersion,
    eventId,
    originDeviceId: envelope.originDeviceId,
    eventType: envelope.eventType,
    eventSource: envelope.eventSource,
    category: envelope.category,
    message: envelope.message ?? '',
    latitude: envelope.latitude ?? '',
    longitude: envelope.longitude ?? '',
    locationAccuracyM: envelope.locationAccuracyM ?? '',
    createdAt: envelope.createdAt,
    expiresAt: envelope.expiresAt,
    maxHops: String(envelope.maxHops),
    priority: envelope.priority,
  };
}
