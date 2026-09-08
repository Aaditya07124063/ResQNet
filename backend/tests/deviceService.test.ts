jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import {
  deleteDevice,
  getPushTokensForUsers,
  listDevices,
  registerDevice,
  removeDevicesByToken,
} from '../src/services/deviceService';

const mockedQuery = pool.query as jest.Mock;

function fakeDeviceRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'device-1',
    user_id: 'user-1',
    platform: 'android',
    push_provider: 'fcm',
    push_token: 'raw-secret-token-value',
    last_seen_at: new Date('2026-01-01T00:00:00Z'),
    created_at: new Date('2026-01-01T00:00:00Z'),
    updated_at: new Date('2026-01-01T00:00:00Z'),
    ...overrides,
  };
}

beforeEach(() => jest.clearAllMocks());

describe('registerDevice', () => {
  it('upserts on (user_id, push_token) conflict and never returns the raw push_token', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [fakeDeviceRow()] });
    const result = await registerDevice('user-1', { platform: 'android', pushProvider: 'fcm', pushToken: 'raw-secret-token-value' });
    expect(mockedQuery.mock.calls[0][0]).toMatch(/ON CONFLICT \(user_id, push_token\)/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['user-1', 'android', 'fcm', 'raw-secret-token-value']);
    expect(result).not.toHaveProperty('pushToken' as never);
    expect(result).not.toHaveProperty('push_token' as never);
  });
});

describe('listDevices', () => {
  it('is scoped to the given user id and never includes push_token', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [fakeDeviceRow()] });
    const result = await listDevices('user-1');
    expect(mockedQuery.mock.calls[0][1]).toEqual(['user-1']);
    expect(result[0]).not.toHaveProperty('pushToken' as never);
  });
});

describe('deleteDevice', () => {
  it('scopes the DELETE to both device id AND owner user id', async () => {
    mockedQuery.mockResolvedValueOnce({ rowCount: 1 });
    await deleteDevice('user-1', 'device-1');
    expect(mockedQuery.mock.calls[0][0]).toMatch(/DELETE FROM devices WHERE id = \$1 AND user_id = \$2/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['device-1', 'user-1']);
  });

  it('404s the same way whether the device does not exist or belongs to someone else', async () => {
    mockedQuery.mockResolvedValueOnce({ rowCount: 0 });
    await expect(deleteDevice('user-1', 'someone-elses-device')).rejects.toMatchObject({ status: 404 });
  });
});

describe('getPushTokensForUsers', () => {
  it('returns [] without querying at all for an empty user list', async () => {
    const result = await getPushTokensForUsers([]);
    expect(result).toEqual([]);
    expect(mockedQuery).not.toHaveBeenCalled();
  });

  it('queries with ANY($1) for a non-empty list', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [{ user_id: 'user-1', push_token: 'tok' }] });
    const result = await getPushTokensForUsers(['user-1', 'user-2']);
    expect(mockedQuery.mock.calls[0][1]).toEqual([['user-1', 'user-2']]);
    expect(result).toEqual([{ userId: 'user-1', token: 'tok' }]);
  });
});

describe('removeDevicesByToken', () => {
  it('is a no-op (no query) for an empty token list', async () => {
    await removeDevicesByToken([]);
    expect(mockedQuery).not.toHaveBeenCalled();
  });

  it('deletes by push_token, never by id or user_id', async () => {
    mockedQuery.mockResolvedValueOnce({ rowCount: 2 });
    await removeDevicesByToken(['dead-token-1', 'dead-token-2']);
    expect(mockedQuery.mock.calls[0][0]).toMatch(/DELETE FROM devices WHERE push_token = ANY\(\$1\)/);
    expect(mockedQuery.mock.calls[0][1]).toEqual([['dead-token-1', 'dead-token-2']]);
  });
});
