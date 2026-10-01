import { isSosSensitiveExpired, retentionPolicyFromEnv } from '../services/retention/retentionPolicy';
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
  // Lifecycle (migration 011). Optional so rows from narrower SELECTs still type-check.
  ops_closed_at?: Date | null;
  sensitive_redacted_at?: Date | null;
  retention_hold_at?: Date | null;
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
  /**
   * True when the message and location were removed under the retention
   * policy (or are past it and awaiting the purge job). The fields above
   * are then null.
   */
  sensitiveRemoved: boolean;
}

/**
 * Whether a closed incident's message and location must no longer be
 * served: already redacted, or past RETENTION_SOS_SENSITIVE_DAYS since
 * closure (not on hold) even if the purge job has not run yet.
 */
export function sosSensitiveRemoved(row: Pick<DbSosEventRow, 'ops_closed_at' | 'sensitive_redacted_at' | 'retention_hold_at'>, now = new Date()): boolean {
  if (row.sensitive_redacted_at) return true;
  return isSosSensitiveExpired(
    { ops_closed_at: row.ops_closed_at ?? null, retention_hold_at: row.retention_hold_at ?? null },
    now,
    retentionPolicyFromEnv(),
  );
}

// pg returns NUMERIC columns as strings (no type parser is registered in
// database/pool.ts) — parsed to JS numbers here, at the single boundary
// where DB rows become API shapes, rather than at every call site.
function toNullableNumber(value: string | null): number | null {
  return value === null ? null : Number(value);
}

export function toSosEvent(row: DbSosEventRow): SosEvent {
  const removed = sosSensitiveRemoved(row);
  return {
    id: row.id,
    eventId: row.event_id,
    eventSource: row.event_source,
    category: row.category,
    message: removed ? null : row.message,
    latitude: removed ? null : toNullableNumber(row.latitude),
    longitude: removed ? null : toNullableNumber(row.longitude),
    locationAccuracyM: removed ? null : toNullableNumber(row.location_accuracy_m),
    status: row.status,
    clientCreatedAt: row.client_created_at.toISOString(),
    serverReceivedAt: row.server_received_at.toISOString(),
    resolvedAt: row.resolved_at ? row.resolved_at.toISOString() : null,
    originVerificationState: row.origin_verification_state,
    sensitiveRemoved: removed,
  };
}
