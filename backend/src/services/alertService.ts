import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import type { CreateAlertInput, UpdateAlertInput } from '../validation/alertSchemas';

// Emergency alerts with explicit provenance. Who may issue which source
// type is decided in the routes (permissions); this service stores and
// serves them, and ingests normalized alerts from source adapters.

export type AlertSourceType =
  | 'official'
  | 'verified_partner'
  | 'international_public'
  | 'resqnet_system'
  | 'community'
  | 'device_sensor';

export interface EmergencyAlert {
  id: string;
  sourceType: AlertSourceType;
  sourceName: string;
  /** Where the original notice can be read (https only). Not covered by the signature. */
  sourceUrl: string | null;
  /** When ResQNet fetched it from an external feed; null for portal-issued alerts. */
  retrievedAt: string | null;
  category: string;
  severity: string;
  status: 'active' | 'resolved' | 'cancelled';
  title: string;
  body: string;
  instructions: string | null;
  area: {
    latitude: number | null;
    longitude: number | null;
    radiusKm: number | null;
    province: string | null;
    district: string | null;
    municipality: string | null;
  };
  issuedAt: string;
  expiresAt: string | null;
  resolvedAt: string | null;
  updatedAt: string;
}

interface DbAlertRow {
  id: string;
  source_type: AlertSourceType;
  source_name: string;
  source_url: string | null;
  retrieved_at: Date | null;
  category: string;
  severity: string;
  status: EmergencyAlert['status'];
  title: string;
  body: string;
  instructions: string | null;
  latitude: number | null;
  longitude: number | null;
  radius_km: number | null;
  province: string | null;
  district: string | null;
  municipality: string | null;
  issued_at: Date;
  expires_at: Date | null;
  resolved_at: Date | null;
  updated_at: Date;
}

export function toAlert(row: DbAlertRow): EmergencyAlert {
  return {
    id: row.id,
    sourceType: row.source_type,
    sourceName: row.source_name,
    sourceUrl: row.source_url ?? null,
    retrievedAt: row.retrieved_at?.toISOString() ?? null,
    category: row.category,
    severity: row.severity,
    status: row.status,
    title: row.title,
    body: row.body,
    instructions: row.instructions,
    area: {
      latitude: row.latitude,
      longitude: row.longitude,
      radiusKm: row.radius_km,
      province: row.province,
      district: row.district,
      municipality: row.municipality,
    },
    issuedAt: row.issued_at.toISOString(),
    expiresAt: row.expires_at?.toISOString() ?? null,
    resolvedAt: row.resolved_at?.toISOString() ?? null,
    updatedAt: row.updated_at.toISOString(),
  };
}

export async function createAlert(employeeId: string, input: CreateAlertInput): Promise<EmergencyAlert> {
  const { rows } = await pool.query<DbAlertRow>(
    `INSERT INTO emergency_alerts
       (source_type, source_name, category, severity, title, body, instructions,
        latitude, longitude, radius_km, province, district, municipality, expires_at, created_by_employee_id,
        source_url)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
     RETURNING *`,
    [
      input.sourceType,
      input.sourceName,
      input.category,
      input.severity,
      input.title,
      input.body,
      input.instructions ?? null,
      input.latitude ?? null,
      input.longitude ?? null,
      input.radiusKm ?? null,
      input.province ?? null,
      input.district ?? null,
      input.municipality ?? null,
      input.expiresAt ?? null,
      employeeId,
      input.sourceUrl ?? null,
    ],
  );
  return toAlert(rows[0]!);
}

export async function getAlert(id: string): Promise<EmergencyAlert> {
  const { rows } = await pool.query<DbAlertRow>('SELECT * FROM emergency_alerts WHERE id = $1', [id]);
  if (!rows[0]) throw HttpError.notFound('Alert not found');
  return toAlert(rows[0]);
}

export async function updateAlert(id: string, input: UpdateAlertInput): Promise<EmergencyAlert> {
  const current = await getAlert(id);
  if (current.status !== 'active' && input.status === undefined) {
    throw HttpError.conflict('A resolved or cancelled alert cannot be edited');
  }
  const ending = input.status === 'resolved' || input.status === 'cancelled';
  const { rows } = await pool.query<DbAlertRow>(
    `UPDATE emergency_alerts SET
       severity = COALESCE($2, severity),
       title = COALESCE($3, title),
       body = COALESCE($4, body),
       instructions = CASE WHEN $5::boolean THEN $6 ELSE instructions END,
       expires_at = CASE WHEN $7::boolean THEN $8::timestamptz ELSE expires_at END,
       status = COALESCE($9, status),
       resolved_at = CASE WHEN $10::boolean THEN now() ELSE resolved_at END
     WHERE id = $1
     RETURNING *`,
    [
      id,
      input.severity ?? null,
      input.title ?? null,
      input.body ?? null,
      input.instructions !== undefined,
      input.instructions ?? null,
      input.expiresAt !== undefined,
      input.expiresAt ?? null,
      input.status ?? null,
      ending,
    ],
  );
  return toAlert(rows[0]!);
}

/** Alerts currently in force (active and not expired), most severe first. */
export async function listActiveAlerts(): Promise<EmergencyAlert[]> {
  const { rows } = await pool.query<DbAlertRow>(
    `SELECT * FROM emergency_alerts
     WHERE status = 'active' AND (expires_at IS NULL OR expires_at > now())
     ORDER BY CASE severity WHEN 'emergency' THEN 0 WHEN 'warning' THEN 1 WHEN 'watch' THEN 2
                            WHEN 'advisory' THEN 3 ELSE 4 END, issued_at DESC
     LIMIT 200`,
  );
  return rows.map(toAlert);
}

/** Every alert (portal view), newest first. */
export async function listAllAlerts(limit = 200): Promise<EmergencyAlert[]> {
  const { rows } = await pool.query<DbAlertRow>('SELECT * FROM emergency_alerts ORDER BY issued_at DESC LIMIT $1', [
    limit,
  ]);
  return rows.map(toAlert);
}
