import { withTransaction } from '../database/pool';
import { logger } from '../utils/logger';
import { notifySeismicCorroboration } from './pushNotificationService';
import type { SeismicReportInput } from '../validation/seismicSchemas';

// Multi-device earthquake corroboration, owned by the ResQNet backend
// (replaces functions/index.js's correlateSeismicEvent Cloud Function and
// its Firestore `seismic_events` collection). Same thresholds as before.
export const SEISMIC_CORRELATION_RADIUS_KM = 50;
export const SEISMIC_CORRELATION_WINDOW_MS = 5_000;
export const SEISMIC_MIN_DEVICES = 3;
/** No second alert for the same area within this period. */
export const SEISMIC_ALERT_COOLDOWN_MS = 10 * 60_000;
const RETENTION = '1 day';

export interface SeismicReportResult {
  reportId: string;
  /** Distinct users (including this one) reporting within the window and radius. */
  corroboratingDeviceCount: number;
  corroborated: boolean;
  /** True when this report triggered the (single) area alert. */
  alertSent: boolean;
}

export function haversineKm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * Stores [input] and clusters it with other users' recent reports.
 * Counts DISTINCT users, so one device reporting repeatedly cannot
 * manufacture corroboration. Runs under an advisory lock so two reports
 * completing the same cluster simultaneously cannot both send an alert.
 */
export async function recordSeismicReport(userId: string, input: SeismicReportInput): Promise<SeismicReportResult> {
  const outcome = await withTransaction(async (client) => {
    await client.query("SELECT pg_advisory_xact_lock(hashtext('seismic-correlation'))");
    await client.query(`DELETE FROM seismic_reports WHERE reported_at < now() - interval '${RETENTION}'`);

    const inserted = await client.query<{ id: string; reported_at: Date }>(
      `INSERT INTO seismic_reports
         (user_id, latitude, longitude, detector_score, sta_lta_ratio, sustained_duration_ms, oscillation_count)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING id, reported_at`,
      [
        userId,
        input.latitude,
        input.longitude,
        input.detectorScore,
        input.staLtaRatio ?? null,
        input.sustainedDurationMs ?? null,
        input.oscillationCount ?? null,
      ],
    );
    const report = inserted.rows[0]!;
    const windowSeconds = SEISMIC_CORRELATION_WINDOW_MS / 1000;

    // Time window in SQL (indexed); distance in JS — the candidate set in a
    // ±5 s window is small.
    const nearby = await client.query<{ user_id: string; latitude: number; longitude: number }>(
      `SELECT user_id, latitude, longitude FROM seismic_reports
       WHERE reported_at BETWEEN $1::timestamptz - make_interval(secs => $2) AND $1::timestamptz + make_interval(secs => $2)`,
      [report.reported_at, windowSeconds],
    );
    const users = new Set<string>([userId]);
    for (const row of nearby.rows) {
      if (haversineKm(input.latitude, input.longitude, row.latitude, row.longitude) <= SEISMIC_CORRELATION_RADIUS_KM) {
        users.add(row.user_id);
      }
    }
    const deviceCount = users.size;
    const corroborated = deviceCount >= SEISMIC_MIN_DEVICES;
    if (!corroborated) return { reportId: report.id, deviceCount, corroborated, alertSent: false };

    const recentAlerts = await client.query<{ latitude: number; longitude: number }>(
      `SELECT latitude, longitude FROM seismic_alerts WHERE created_at > now() - make_interval(secs => $1)`,
      [SEISMIC_ALERT_COOLDOWN_MS / 1000],
    );
    const alreadyAlerted = recentAlerts.rows.some(
      (a) => haversineKm(input.latitude, input.longitude, a.latitude, a.longitude) <= SEISMIC_CORRELATION_RADIUS_KM,
    );
    if (alreadyAlerted) return { reportId: report.id, deviceCount, corroborated, alertSent: false };

    await client.query('INSERT INTO seismic_alerts (latitude, longitude, device_count) VALUES ($1, $2, $3)', [
      input.latitude,
      input.longitude,
      deviceCount,
    ]);
    return { reportId: report.id, deviceCount, corroborated, alertSent: true };
  });

  if (outcome.alertSent) {
    // After commit, best-effort: a push failure must not fail the report.
    await notifySeismicCorroboration({
      latitude: input.latitude,
      longitude: input.longitude,
      deviceCount: outcome.deviceCount,
    }).catch((err: unknown) => logger.warn({ err }, 'Seismic corroboration push failed'));
  }

  return {
    reportId: outcome.reportId,
    corroboratingDeviceCount: outcome.deviceCount,
    corroborated: outcome.corroborated,
    alertSent: outcome.alertSent,
  };
}
