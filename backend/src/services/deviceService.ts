import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { toDevice, type DbDeviceRow, type Device } from '../models/Device';
import type { RegisterDeviceInput } from '../validation/deviceSchemas';

/**
 * Registers (or re-registers) a device for the authenticated user.
 * `uq_devices_user_token (user_id, push_token)` makes this idempotent —
 * the same device re-registering the same current token (app reopen,
 * periodic refresh with an unchanged token) just bumps `last_seen_at`
 * rather than erroring or creating a duplicate row. A genuinely refreshed
 * token (FCM issues a new one) is a NEW token value, so it creates a new
 * row — the old one is left as-is (still valid until FCM itself expires
 * it) rather than guessing at when to prune it.
 */
export async function registerDevice(userId: string, input: RegisterDeviceInput): Promise<Device> {
  const { rows } = await pool.query<DbDeviceRow>(
    `INSERT INTO devices (user_id, platform, push_provider, push_token)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (user_id, push_token)
     DO UPDATE SET platform = $2, push_provider = $3, last_seen_at = now()
     RETURNING *`,
    [userId, input.platform, input.pushProvider, input.pushToken],
  );
  return toDevice(rows[0]!);
}

export async function listDevices(userId: string): Promise<Device[]> {
  const { rows } = await pool.query<DbDeviceRow>(
    'SELECT * FROM devices WHERE user_id = $1 ORDER BY last_seen_at DESC',
    [userId],
  );
  return rows.map(toDevice);
}

/** Ownership-scoped — the same 404 whether the device doesn't exist or
 * belongs to someone else, matching every other owned-resource delete in
 * this codebase (trustedContactsService.ts, sosService.ts). */
export async function deleteDevice(userId: string, deviceId: string): Promise<void> {
  const { rowCount } = await pool.query('DELETE FROM devices WHERE id = $1 AND user_id = $2', [deviceId, userId]);
  if (!rowCount) {
    throw HttpError.notFound('Device not found');
  }
}

/**
 * Internal-only (never exposed through an API response): the raw push
 * tokens for a set of users, for pushNotificationService.ts to actually
 * send to. Excludes nothing by account_status here — the caller decides
 * which users are eligible to be notified at all.
 */
export async function getPushTokensForUsers(userIds: string[]): Promise<{ userId: string; token: string }[]> {
  if (userIds.length === 0) return [];
  const { rows } = await pool.query<{ user_id: string; push_token: string }>(
    'SELECT user_id, push_token FROM devices WHERE user_id = ANY($1)',
    [userIds],
  );
  return rows.map((r) => ({ userId: r.user_id, token: r.push_token }));
}

/** Removes device rows FCM itself reported as permanently invalid/
 * unregistered — never called for any other kind of send failure. */
export async function removeDevicesByToken(tokens: string[]): Promise<void> {
  if (tokens.length === 0) return;
  await pool.query('DELETE FROM devices WHERE push_token = ANY($1)', [tokens]);
}
