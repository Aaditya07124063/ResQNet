import { pool } from '../database/pool';

/**
 * Thin CRUD over `admin_settings` — the table Phase 14's report-threshold
 * logic (reportService.ts's maybeOpenReviewCase) already reads from but
 * had no API to populate ("no Phase 15 admin API exists yet to set
 * these" — docs/DONE.md's Phase 14 entry). Deliberately generic
 * (key/value/description) rather than a fixed set of typed settings,
 * matching the column design itself (JSONB value, no per-setting schema)
 * and the project's "modular, not hardcoded" principle already applied to
 * employee_permissions.
 */
export interface AdminSetting {
  key: string;
  value: unknown;
  description: string | null;
  updatedAt: string;
  updatedByEmployeeId: string | null;
}

interface DbAdminSettingRow {
  key: string;
  value: unknown; // JSONB — node-pg parses this to its native JS value already
  description: string | null;
  updated_at: Date;
  updated_by_employee_id: string | null;
}

function toAdminSetting(row: DbAdminSettingRow): AdminSetting {
  return {
    key: row.key,
    value: row.value,
    description: row.description,
    updatedAt: row.updated_at.toISOString(),
    updatedByEmployeeId: row.updated_by_employee_id,
  };
}

export async function listSettings(): Promise<AdminSetting[]> {
  const { rows } = await pool.query<DbAdminSettingRow>('SELECT * FROM admin_settings ORDER BY key ASC');
  return rows.map(toAdminSetting);
}

export async function getSetting(key: string): Promise<AdminSetting | null> {
  const { rows } = await pool.query<DbAdminSettingRow>('SELECT * FROM admin_settings WHERE key = $1', [key]);
  return rows[0] ? toAdminSetting(rows[0]) : null;
}

export async function upsertSetting(
  key: string,
  value: unknown,
  description: string | null,
  updatedByEmployeeId: string,
): Promise<AdminSetting> {
  const { rows } = await pool.query<DbAdminSettingRow>(
    `INSERT INTO admin_settings (key, value, description, updated_by_employee_id)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (key) DO UPDATE SET value = $2, description = $3, updated_by_employee_id = $4
     RETURNING *`,
    [key, JSON.stringify(value), description, updatedByEmployeeId],
  );
  return toAdminSetting(rows[0]!);
}
