export interface DbDeviceKeyRow {
  id: string;
  user_id: string;
  device_id: string;
  key_id: string;
  public_key: string;
  algorithm: string;
  registered_at: Date;
  revoked_at: Date | null;
}

/** Deliberately omits `public_key` from the normal API response shape —
 * not because it's secret (it isn't), but because a client that just
 * registered it has no use for it echoed back, matching the existing
 * `Device`/`push_token` convention in models/Device.ts. */
export interface DeviceKey {
  id: string;
  deviceId: string;
  keyId: string;
  algorithm: string;
  registeredAt: string;
  revokedAt: string | null;
}

export function toDeviceKey(row: DbDeviceKeyRow): DeviceKey {
  return {
    id: row.id,
    deviceId: row.device_id,
    keyId: row.key_id,
    algorithm: row.algorithm,
    registeredAt: row.registered_at.toISOString(),
    revokedAt: row.revoked_at ? row.revoked_at.toISOString() : null,
  };
}

/** Internal-only shape (never returned from an API response) — the one
 * place `public_key`/`revoked_at`/`user_id` are actually read, for
 * signature verification and reconciliation. Mirrors the
 * `getPushTokensForUsers` internal-path convention in deviceService.ts. */
export interface DeviceKeyRecord {
  userId: string;
  deviceId: string;
  keyId: string;
  publicKey: string;
  revokedAt: string | null;
}

export function toDeviceKeyRecord(row: DbDeviceKeyRow): DeviceKeyRecord {
  return {
    userId: row.user_id,
    deviceId: row.device_id,
    keyId: row.key_id,
    publicKey: row.public_key,
    revokedAt: row.revoked_at ? row.revoked_at.toISOString() : null,
  };
}
