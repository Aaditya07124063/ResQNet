export interface DbDeviceRow {
  id: string;
  user_id: string;
  platform: 'android' | 'ios' | 'web';
  push_provider: string;
  push_token: string;
  last_seen_at: Date;
  created_at: Date;
  updated_at: Date;
}

/** Deliberately omits `push_token` — a client never needs its own raw
 * token echoed back (it just registered it), and this is the shape
 * returned from list/register responses. See deviceService.ts's
 * `getDevicePushTokens` for the one internal, non-API-exposed path that
 * DOES read tokens (for actually sending a push). */
export interface Device {
  id: string;
  platform: DbDeviceRow['platform'];
  pushProvider: string;
  lastSeenAt: string;
  createdAt: string;
}

export function toDevice(row: DbDeviceRow): Device {
  return {
    id: row.id,
    platform: row.platform,
    pushProvider: row.push_provider,
    lastSeenAt: row.last_seen_at.toISOString(),
    createdAt: row.created_at.toISOString(),
  };
}
