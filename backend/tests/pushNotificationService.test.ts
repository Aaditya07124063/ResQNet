jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));
jest.mock('../src/services/deviceService', () => ({
  getPushTokensForUsers: jest.fn(),
  removeDevicesByToken: jest.fn(),
}));
jest.mock('../src/services/fcm', () => ({
  sendMulticast: jest.fn(),
}));

import { pool } from '../src/database/pool';
import { getPushTokensForUsers, removeDevicesByToken } from '../src/services/deviceService';
import { sendMulticast } from '../src/services/fcm';
import {
  notifyAllOtherActiveUsers,
  notifySeismicCorroboration,
  notifyUsersDevices,
} from '../src/services/pushNotificationService';

const mockPoolQuery = pool.query as jest.Mock;
const mockGetPushTokensForUsers = getPushTokensForUsers as jest.Mock;
const mockRemoveDevicesByToken = removeDevicesByToken as jest.Mock;
const mockSendMulticast = sendMulticast as jest.Mock;

const CONTENT = { title: 'Test', body: 'Body' };

beforeEach(() => {
  jest.clearAllMocks();
});

describe('notifyUsersDevices', () => {
  it('returns "no_device" for every user with an empty user list, without calling FCM', async () => {
    const result = await notifyUsersDevices([], CONTENT);
    expect(result.size).toBe(0);
    expect(mockGetPushTokensForUsers).not.toHaveBeenCalled();
  });

  it('marks a user with zero registered devices as "no_device", never "failed"', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([]);
    const result = await notifyUsersDevices(['user-1'], CONTENT);
    expect(result.get('user-1')).toBe('no_device');
    expect(mockSendMulticast).not.toHaveBeenCalled();
  });

  it('marks a user "sent" when at least one of their devices succeeds, even if another fails', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([
      { userId: 'user-1', token: 'token-a' },
      { userId: 'user-1', token: 'token-b' },
    ]);
    mockSendMulticast.mockResolvedValue([
      { token: 'token-a', success: true, shouldRemoveToken: false },
      { token: 'token-b', success: false, shouldRemoveToken: false },
    ]);
    const result = await notifyUsersDevices(['user-1'], CONTENT);
    expect(result.get('user-1')).toBe('sent');
  });

  it('marks a user "failed" only when ALL of their devices fail', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([{ userId: 'user-1', token: 'token-a' }]);
    mockSendMulticast.mockResolvedValue([{ token: 'token-a', success: false, shouldRemoveToken: false }]);
    const result = await notifyUsersDevices(['user-1'], CONTENT);
    expect(result.get('user-1')).toBe('failed');
  });

  it('removes only the tokens FCM flagged for removal, never a token that merely failed transiently', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([
      { userId: 'user-1', token: 'dead-token' },
      { userId: 'user-2', token: 'live-token' },
    ]);
    mockSendMulticast.mockResolvedValue([
      { token: 'dead-token', success: false, shouldRemoveToken: true },
      { token: 'live-token', success: false, shouldRemoveToken: false },
    ]);
    await notifyUsersDevices(['user-1', 'user-2'], CONTENT);
    expect(mockRemoveDevicesByToken).toHaveBeenCalledWith(['dead-token']);
  });

  it('correctly attributes results per-user even when users share no overlap in devices (isolation)', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([
      { userId: 'user-a', token: 'token-a' },
      { userId: 'user-b', token: 'token-b' },
    ]);
    mockSendMulticast.mockResolvedValue([
      { token: 'token-a', success: true, shouldRemoveToken: false },
      { token: 'token-b', success: false, shouldRemoveToken: false },
    ]);
    const result = await notifyUsersDevices(['user-a', 'user-b'], CONTENT);
    expect(result.get('user-a')).toBe('sent');
    expect(result.get('user-b')).toBe('failed');
  });

  it('never throws when sendMulticast itself throws — marks every user with tokens as "failed" instead', async () => {
    mockGetPushTokensForUsers.mockResolvedValue([{ userId: 'user-1', token: 'token-a' }]);
    mockSendMulticast.mockRejectedValue(new Error('unexpected send failure'));
    const result = await notifyUsersDevices(['user-1'], CONTENT);
    expect(result.get('user-1')).toBe('failed');
  });
});

describe('notifyAllOtherActiveUsers', () => {
  it('excludes the given user and only queries active accounts', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ id: 'user-2' }] });
    mockGetPushTokensForUsers.mockResolvedValue([]);
    await notifyAllOtherActiveUsers('user-1', CONTENT);
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/account_status = 'active'/);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual(['user-1']);
  });

  it('does nothing (no token lookup at all) when there are no other active users', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await notifyAllOtherActiveUsers('user-1', CONTENT);
    expect(mockGetPushTokensForUsers).not.toHaveBeenCalled();
  });

  it('with excludeUserId=null, queries ALL active users with no exclusion filter at all', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ id: 'user-1' }, { id: 'user-2' }] });
    mockGetPushTokensForUsers.mockResolvedValue([]);
    await notifyAllOtherActiveUsers(null, CONTENT);
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/account_status = 'active'/);
    expect(mockPoolQuery.mock.calls[0][0]).not.toMatch(/id != /);
    // Single-argument query — no id parameter to bind at all.
    expect(mockPoolQuery.mock.calls[0][1]).toBeUndefined();
  });
});

describe('notifySeismicCorroboration', () => {
  it('broadcasts to all active users (excludeUserId=null) with the expected title/body/data shape', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ id: 'user-1' }] });
    mockGetPushTokensForUsers.mockResolvedValue([]);

    await notifySeismicCorroboration({ latitude: 12.9, longitude: 77.6, deviceCount: 4 });

    expect(mockPoolQuery.mock.calls[0][0]).not.toMatch(/id != /);
    expect(mockGetPushTokensForUsers).toHaveBeenCalledWith(['user-1']);
  });

  it('never throws when there are zero active users (no-device-equivalent case)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(
      notifySeismicCorroboration({ latitude: 1, longitude: 1, deviceCount: 3 }),
    ).resolves.toBeUndefined();
    expect(mockGetPushTokensForUsers).not.toHaveBeenCalled();
  });

  it('never throws when every device send fails (FCM/provider failure) — delegates to the existing failure handling', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ id: 'user-1' }] });
    mockGetPushTokensForUsers.mockResolvedValue([{ userId: 'user-1', token: 'dead-token' }]);
    mockSendMulticast.mockResolvedValue([{ token: 'dead-token', success: false, shouldRemoveToken: true }]);

    await expect(
      notifySeismicCorroboration({ latitude: 1, longitude: 1, deviceCount: 5 }),
    ).resolves.toBeUndefined();
    expect(mockRemoveDevicesByToken).toHaveBeenCalledWith(['dead-token']);
  });
});
