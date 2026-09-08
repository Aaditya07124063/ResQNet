jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import {
  approximateDistanceLabel,
  findNearbyEligibleUsers,
  getNearbyPreference,
  setNearbyPreference,
  upsertNearbyLocationIfEnabled,
} from '../src/services/nearbyAlertService';

const mockPoolQuery = pool.query as jest.Mock;

beforeEach(() => {
  jest.clearAllMocks();
});

describe('getNearbyPreference', () => {
  it('defaults to disabled/null-radius when the user has no row yet', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    const pref = await getNearbyPreference('user-1');
    expect(pref).toEqual({ enabled: false, radiusM: null });
  });

  it('returns the stored preference', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ enabled: true, radius_m: 2000 }] });
    const pref = await getNearbyPreference('user-1');
    expect(pref).toEqual({ enabled: true, radiusM: 2000 });
  });
});

describe('setNearbyPreference', () => {
  it('upserts the preference', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await setNearbyPreference('user-1', { enabled: true, radiusM: 3000 });
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/INSERT INTO nearby_emergency_preferences/);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual(['user-1', true, 3000]);
  });

  it('deletes any stored approximate location when turning the preference OFF (Section 12/30 privacy)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] }).mockResolvedValueOnce({ rows: [] });
    await setNearbyPreference('user-1', { enabled: false, radiusM: null });
    expect(mockPoolQuery).toHaveBeenCalledTimes(2);
    expect(mockPoolQuery.mock.calls[1][0]).toMatch(/DELETE FROM nearby_alert_locations/);
    expect(mockPoolQuery.mock.calls[1][1]).toEqual(['user-1']);
  });

  it('does NOT delete the stored location when turning the preference ON', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await setNearbyPreference('user-1', { enabled: true, radiusM: null });
    expect(mockPoolQuery).toHaveBeenCalledTimes(1);
  });
});

describe('upsertNearbyLocationIfEnabled', () => {
  it('does nothing and returns false when the preference is disabled', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] }); // getNearbyPreference -> no row -> disabled
    const stored = await upsertNearbyLocationIfEnabled('user-1', 27.7, 85.3);
    expect(stored).toBe(false);
    expect(mockPoolQuery).toHaveBeenCalledTimes(1); // only the preference read, no upsert
  });

  it('upserts and returns true when the preference is enabled', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [{ enabled: true, radius_m: null }] })
      .mockResolvedValueOnce({ rows: [] });
    const stored = await upsertNearbyLocationIfEnabled('user-1', 27.7, 85.3);
    expect(stored).toBe(true);
    expect(mockPoolQuery.mock.calls[1][0]).toMatch(/INSERT INTO nearby_alert_locations/);
    expect(mockPoolQuery.mock.calls[1][1]).toEqual(['user-1', 27.7, 85.3]);
  });
});

describe('findNearbyEligibleUsers', () => {
  const REPORTER = 'reporter-1';
  const REPORTER_LAT = 27.7172;
  const REPORTER_LNG = 85.324;

  it('returns [] without a second query when the bounding-box query finds no candidates', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    const result = await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);
    expect(result).toEqual([]);
    expect(mockPoolQuery).toHaveBeenCalledTimes(1);
  });

  it('excludes the reporter via the query itself (WHERE nal.user_id != $1)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/user_id != \$1/);
    expect(mockPoolQuery.mock.calls[0][1][0]).toBe(REPORTER);
  });

  it('only queries account_status = active and preference enabled = true (matches the notifyAllOtherActiveUsers eligibility bar it replaces)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);
    const sql = mockPoolQuery.mock.calls[0][0];
    expect(sql).toMatch(/account_status = 'active'/);
    expect(sql).toMatch(/p\.enabled = TRUE/);
  });

  it('includes a candidate within their effective (default) radius', async () => {
    // ~500m north of the reporter.
    const nearLat = REPORTER_LAT + 0.0045;
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [{ user_id: 'near-user', latitude: String(nearLat), longitude: String(REPORTER_LNG) }] })
      .mockResolvedValueOnce({ rows: [{ user_id: 'near-user', latitude: String(nearLat), longitude: String(REPORTER_LNG), radius_m: null }] });

    const result = await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);

    expect(result).toHaveLength(1);
    expect(result[0]!.userId).toBe('near-user');
    expect(result[0]!.distanceM).toBeGreaterThan(0);
    expect(result[0]!.distanceM).toBeLessThan(5_000); // NEARBY_ALERT_DEFAULT_RADIUS_M
  });

  it('excludes a candidate outside their effective radius (radius boundary test)', async () => {
    // ~50km away — well outside both the 5km default and even a 50km max override.
    const farLat = REPORTER_LAT + 0.5;
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [{ user_id: 'far-user', latitude: String(farLat), longitude: String(REPORTER_LNG) }] })
      .mockResolvedValueOnce({ rows: [{ user_id: 'far-user', latitude: String(farLat), longitude: String(REPORTER_LNG), radius_m: null }] });

    const result = await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);

    expect(result).toEqual([]);
  });

  it('respects a per-user radius_m override larger than the default', async () => {
    // ~8km away — outside the 5km default, inside a 10km personal override.
    const lat = REPORTER_LAT + 0.072;
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [{ user_id: 'wide-radius-user', latitude: String(lat), longitude: String(REPORTER_LNG) }] })
      .mockResolvedValueOnce({ rows: [{ user_id: 'wide-radius-user', latitude: String(lat), longitude: String(REPORTER_LNG), radius_m: 10_000 }] });

    const result = await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);

    expect(result).toHaveLength(1);
    expect(result[0]!.userId).toBe('wide-radius-user');
  });

  it('returns multiple eligible users, each with their own distance', async () => {
    const closeLat = REPORTER_LAT + 0.001;
    const midLat = REPORTER_LAT + 0.01;
    mockPoolQuery
      .mockResolvedValueOnce({
        rows: [
          { user_id: 'user-a', latitude: String(closeLat), longitude: String(REPORTER_LNG) },
          { user_id: 'user-b', latitude: String(midLat), longitude: String(REPORTER_LNG) },
        ],
      })
      .mockResolvedValueOnce({
        rows: [
          { user_id: 'user-a', latitude: String(closeLat), longitude: String(REPORTER_LNG), radius_m: null },
          { user_id: 'user-b', latitude: String(midLat), longitude: String(REPORTER_LNG), radius_m: null },
        ],
      });

    const result = await findNearbyEligibleUsers(REPORTER, REPORTER_LAT, REPORTER_LNG);

    expect(result).toHaveLength(2);
    const distances = new Map(result.map((r) => [r.userId, r.distanceM]));
    expect(distances.get('user-a')!).toBeLessThan(distances.get('user-b')!);
  });
});

describe('approximateDistanceLabel', () => {
  it('never exposes the exact meter value — only a coarse bucket label', () => {
    expect(approximateDistanceLabel(50)).toBe('Very close by');
    expect(approximateDistanceLabel(500)).toBe('Within 1 km');
    expect(approximateDistanceLabel(2_000)).toBe('Within 3 km');
    expect(approximateDistanceLabel(4_000)).toBe('Within 5 km');
    expect(approximateDistanceLabel(4_999)).toBe('Within 5 km');
    expect(approximateDistanceLabel(20_000)).toBe('Within your area');
  });
});
