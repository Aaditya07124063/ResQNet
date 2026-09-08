import { pool } from '../database/pool';
import { env } from '../config/env';
import type { UpdateNearbyPreferenceInput } from '../validation/nearbyAlertSchemas';

/**
 * Geospatial approach (Section 11 of the communication-phase spec):
 * PostGIS was evaluated and deliberately NOT introduced. This project runs
 * a plain, unmodified `pg` connection against whatever PostgreSQL instance
 * ops has provisioned (see database/pool.ts) — there is no confirmation
 * PostGIS is installed there, and `CREATE EXTENSION postgis` is a
 * privileged, infra-level change this phase has no authorization to make
 * on a production database. Given the current user-population scale, a
 * plain btree-indexed bounding-box pre-filter (idx_nearby_alert_locations_lat/lng,
 * 003_communication_and_nearby_alerts.sql) followed by an exact Haversine
 * distance check in application code is accurate, adequately fast, and
 * introduces zero new infrastructure risk. If usage ever outgrows this,
 * PostGIS (or a dedicated geo-index service) is the documented next step
 * — not a redesign, since the query boundary (this file) is the only
 * place that would need to change.
 *
 * Concrete scaling boundary (re-confirmed live against a real local
 * Postgres instance, not just estimated): the bounding-box pre-filter is
 * indexed (idx_nearby_alert_locations_lat/lng), so its cost scales with
 * the number of opted-in users whose location falls within the box
 * around one SOS, not with the total user count — the same shape as any
 * other indexed range query in this codebase. The place this genuinely
 * degrades is a single dense area (e.g. tens of thousands of opted-in
 * users within a few km of each other, such as a large city where
 * nearby-alerts is heavily adopted) triggering one SOS: the per-row
 * Haversine pass after the box filter is O(candidates), all in Node,
 * single-threaded, per request. A few hundred candidates is
 * imperceptible; tens of thousands per single SOS is the point PostGIS's
 * native spatial index (KNN/ST_DWithin, done inside Postgres, not
 * candidate-by-candidate in application code) would start mattering.
 * There is no evidence this project is anywhere near that today — this
 * is a documented future trigger condition, not a current problem.
 */

export interface NearbyPreference {
  enabled: boolean;
  radiusM: number | null;
}

interface DbPreferenceRow {
  enabled: boolean;
  radius_m: number | null;
}

const DEFAULT_PREFERENCE: NearbyPreference = { enabled: false, radiusM: null };

export async function getNearbyPreference(userId: string): Promise<NearbyPreference> {
  const { rows } = await pool.query<DbPreferenceRow>(
    'SELECT enabled, radius_m FROM nearby_emergency_preferences WHERE user_id = $1',
    [userId],
  );
  const row = rows[0];
  if (!row) return DEFAULT_PREFERENCE;
  return { enabled: row.enabled, radiusM: row.radius_m };
}

/**
 * Sets the preference. Turning it OFF also deletes any stored approximate
 * location (Section 12/30: don't retain what you no longer have a
 * purpose for) — a user who opts out has their location data removed from
 * this feature immediately, not just "stopped being used".
 */
export async function setNearbyPreference(
  userId: string,
  input: UpdateNearbyPreferenceInput,
): Promise<NearbyPreference> {
  await pool.query(
    `INSERT INTO nearby_emergency_preferences (user_id, enabled, radius_m)
     VALUES ($1, $2, $3)
     ON CONFLICT (user_id) DO UPDATE SET enabled = $2, radius_m = $3`,
    [userId, input.enabled, input.radiusM],
  );
  if (!input.enabled) {
    await pool.query('DELETE FROM nearby_alert_locations WHERE user_id = $1', [userId]);
  }
  return { enabled: input.enabled, radiusM: input.radiusM };
}

/**
 * Upserts the caller's approximate location for nearby-matching. Requires
 * the preference to already be enabled — this is not a general-purpose
 * location endpoint, and silently accepting/storing a location for a user
 * who has nearby alerts OFF would defeat the point of the preference.
 * Returns false (no-op, not an error) when the preference is off, so the
 * Flutter client can simply stop calling this rather than branch on a
 * thrown exception for an entirely expected state.
 */
export async function upsertNearbyLocationIfEnabled(
  userId: string,
  latitude: number,
  longitude: number,
): Promise<boolean> {
  const preference = await getNearbyPreference(userId);
  if (!preference.enabled) return false;
  await pool.query(
    `INSERT INTO nearby_alert_locations (user_id, latitude, longitude, updated_at)
     VALUES ($1, $2, $3, now())
     ON CONFLICT (user_id) DO UPDATE SET latitude = $2, longitude = $3, updated_at = now()`,
    [userId, latitude, longitude],
  );
  return true;
}

export interface NearbyEligibleUser {
  userId: string;
  distanceM: number;
}

const EARTH_RADIUS_M = 6_371_000;
const METERS_PER_DEGREE_LAT = 111_320;

function toRadians(deg: number): number {
  return (deg * Math.PI) / 180;
}

/** Great-circle distance in meters. */
function haversineDistanceM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const dLat = toRadians(lat2 - lat1);
  const dLng = toRadians(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2)) * Math.sin(dLng / 2) ** 2;
  return EARTH_RADIUS_M * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

interface DbNearbyCandidateRow {
  user_id: string;
  latitude: string;
  longitude: string;
}

/**
 * Finds ResQNet users eligible to receive a nearby-emergency alert for an
 * SOS at (latitude, longitude), reported by `reporterUserId`.
 *
 * Applies, in order:
 *   1. a bounding-box pre-filter (indexed, bounds the candidate set before
 *      any per-row math — Section 32: never an unbounded full-table scan);
 *   2. `account_status = 'active'` (same eligibility bar
 *      notifyAllOtherActiveUsers already used for the broadcast this
 *      replaces — suspended/deleted/review_required users are excluded);
 *   3. `nearby_emergency_preferences.enabled = true` (redundant with
 *      upsertNearbyLocationIfEnabled only ever storing a location for
 *      enabled users, but checked again here for defense in depth — a
 *      preference flip to OFF must take effect even if a location row
 *      somehow still existed);
 *   4. excludes the reporter themselves;
 *   5. an exact Haversine distance <= the effective radius (the user's own
 *      `radius_m` override, else `env.NEARBY_ALERT_DEFAULT_RADIUS_M`).
 *
 * Returns each eligible user at most once (SQL `DISTINCT` isn't needed —
 * `nearby_alert_locations` is one row per user by primary key — but
 * duplicate PREVENTION for the resulting `sos_recipients` rows is still
 * enforced independently by `uq_sos_recipients_nearby_unique`).
 */
export async function findNearbyEligibleUsers(
  reporterUserId: string,
  latitude: number,
  longitude: number,
): Promise<NearbyEligibleUser[]> {
  // Bounding box sized to the LARGEST possible configured radius (a
  // per-user override could exceed the default) — an individual
  // candidate's own effective radius is still checked precisely below,
  // this box only has to be big enough not to exclude anyone who might
  // qualify.
  const maxPossibleRadiusM = 50_000; // matches nearby_emergency_preferences.radius_m's CHECK upper bound
  const latDeltaDeg = maxPossibleRadiusM / METERS_PER_DEGREE_LAT;
  const lngDeltaDeg =
    maxPossibleRadiusM / (METERS_PER_DEGREE_LAT * Math.max(Math.cos(toRadians(latitude)), 0.01));

  const { rows } = await pool.query<DbNearbyCandidateRow>(
    `SELECT nal.user_id, nal.latitude, nal.longitude
     FROM nearby_alert_locations nal
     JOIN users u ON u.id = nal.user_id
     JOIN nearby_emergency_preferences p ON p.user_id = nal.user_id
     WHERE u.account_status = 'active'
       AND p.enabled = TRUE
       AND nal.user_id != $1
       AND nal.latitude BETWEEN $2 AND $3
       AND nal.longitude BETWEEN $4 AND $5`,
    [
      reporterUserId,
      latitude - latDeltaDeg,
      latitude + latDeltaDeg,
      longitude - lngDeltaDeg,
      longitude + lngDeltaDeg,
    ],
  );
  if (rows.length === 0) return [];

  // Per-user effective radius requires a second lookup (radius_m lives on
  // nearby_emergency_preferences, already joined above but not selected —
  // selecting it directly avoids a further query).
  const { rows: withRadius } = await pool.query<DbNearbyCandidateRow & { radius_m: number | null }>(
    `SELECT nal.user_id, nal.latitude, nal.longitude, p.radius_m
     FROM nearby_alert_locations nal
     JOIN nearby_emergency_preferences p ON p.user_id = nal.user_id
     WHERE nal.user_id = ANY($1)`,
    [rows.map((r) => r.user_id)],
  );

  const eligible: NearbyEligibleUser[] = [];
  for (const candidate of withRadius) {
    const effectiveRadiusM = candidate.radius_m ?? env.NEARBY_ALERT_DEFAULT_RADIUS_M;
    const distanceM = haversineDistanceM(
      latitude,
      longitude,
      Number(candidate.latitude),
      Number(candidate.longitude),
    );
    if (distanceM <= effectiveRadiusM) {
      eligible.push({ userId: candidate.user_id, distanceM });
    }
  }
  return eligible;
}

/** A coarse, non-precise distance description — never exposes the exact
 * meter value to a nearby recipient (Section 12: minimum necessary
 * information only). Buckets are deliberately wide. */
export function approximateDistanceLabel(distanceM: number): string {
  if (distanceM < 250) return 'Very close by';
  if (distanceM < 1_000) return 'Within 1 km';
  if (distanceM < 3_000) return 'Within 3 km';
  if (distanceM < 5_000) return 'Within 5 km';
  return 'Within your area';
}
