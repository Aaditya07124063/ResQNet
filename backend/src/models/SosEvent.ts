export type OriginVerificationState = 'not_applicable' | 'verified' | 'unverified_unregistered';

export interface DbSosEventRow {
  id: string;
  event_id: string;
  user_id: string | null;
  event_source: 'manual' | 'crash_detection' | 'earthquake_detection';
  category: string;
  message: string | null;
  latitude: string | null;
  longitude: string | null;
  location_accuracy_m: string | null;
  status: 'open' | 'acknowledged' | 'resolved' | 'false_alarm';
  client_created_at: Date;
  server_received_at: Date;
  resolved_at: Date | null;
  origin_device_id: string | null;
  origin_key_id: string | null;
  origin_signature: string | null;
  origin_claimed_user_id: string | null;
  origin_verification_state: OriginVerificationState;
  origin_envelope_raw: unknown | null;
}

/** Deliberately omits `user_id` — every route this is returned from is
 * already scoped to the caller's own id, so there is nothing to add by
 * echoing it back. Also omits origin_device_id/origin_key_id/
 * origin_signature/origin_claimed_user_id — internal verification/audit
 * detail, not something a client needs back; only the human-meaningful
 * `originVerificationState` is surfaced, so a relay device's UI can
 * honestly say "relayed" vs. "origin verified" rather than collapsing the
 * two (see the cryptographic-architecture plan's trust-tier model). */
export interface SosEvent {
  id: string;
  eventId: string;
  eventSource: DbSosEventRow['event_source'];
  category: string;
  message: string | null;
  latitude: number | null;
  longitude: number | null;
  locationAccuracyM: number | null;
  status: DbSosEventRow['status'];
  clientCreatedAt: string;
  serverReceivedAt: string;
  resolvedAt: string | null;
  originVerificationState: OriginVerificationState;
}

// pg returns NUMERIC columns as strings (no type parser is registered in
// database/pool.ts) — parsed to JS numbers here, at the single boundary
// where DB rows become API shapes, rather than at every call site.
function toNullableNumber(value: string | null): number | null {
  return value === null ? null : Number(value);
}

export function toSosEvent(row: DbSosEventRow): SosEvent {
  return {
    id: row.id,
    eventId: row.event_id,
    eventSource: row.event_source,
    category: row.category,
    message: row.message,
    latitude: toNullableNumber(row.latitude),
    longitude: toNullableNumber(row.longitude),
    locationAccuracyM: toNullableNumber(row.location_accuracy_m),
    status: row.status,
    clientCreatedAt: row.client_created_at.toISOString(),
    serverReceivedAt: row.server_received_at.toISOString(),
    resolvedAt: row.resolved_at ? row.resolved_at.toISOString() : null,
    originVerificationState: row.origin_verification_state,
  };
}
