jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));
jest.mock('../src/services/pushNotificationService', () => ({
  notifySeismicCorroboration: jest.fn().mockResolvedValue(undefined),
}));

import { withTransaction } from '../src/database/pool';
import { notifySeismicCorroboration } from '../src/services/pushNotificationService';
import { haversineKm, recordSeismicReport } from '../src/services/seismicService';

const mockWithTransaction = withTransaction as jest.Mock;
const mockNotify = notifySeismicCorroboration as jest.Mock;

const KATHMANDU = { latitude: 27.7172, longitude: 85.324 };
const report = { ...KATHMANDU, detectorScore: 0.8, staLtaRatio: 4.2, sustainedDurationMs: 1500, oscillationCount: 9 };

/** Fake transaction client: lock, prune, insert, window query, [alert lookup, alert insert]. */
function transaction(nearby: Array<{ user_id: string; latitude: number; longitude: number }>, recentAlerts: unknown[] = []) {
  const query = jest.fn(async (sql: string, _params?: unknown[]) => {
    if (sql.includes('INSERT INTO seismic_reports')) return { rows: [{ id: 'report-1', reported_at: new Date() }] };
    if (sql.includes('FROM seismic_reports')) return { rows: nearby };
    if (sql.includes('FROM seismic_alerts')) return { rows: recentAlerts };
    return { rows: [] };
  });
  mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) => work({ query }));
  return query;
}

const near = (userId: string, dLat = 0.01) => ({ user_id: userId, latitude: KATHMANDU.latitude + dLat, longitude: KATHMANDU.longitude });

beforeEach(() => jest.clearAllMocks());

describe('recordSeismicReport', () => {
  it('stores the report for the session user and serializes clustering with an advisory lock', async () => {
    const query = transaction([near('user-1', 0)]);
    const result = await recordSeismicReport('user-1', report);

    expect(query.mock.calls[0]![0]).toMatch(/pg_advisory_xact_lock/);
    const insert = query.mock.calls.find(([sql]) => sql.includes('INSERT INTO seismic_reports'))!;
    expect(insert[1]).toEqual(['user-1', 27.7172, 85.324, 0.8, 4.2, 1500, 9]);
    expect(result).toEqual({ reportId: 'report-1', corroboratingDeviceCount: 1, corroborated: false, alertSent: false });
    expect(mockNotify).not.toHaveBeenCalled();
  });

  it('counts distinct users, so one device repeating itself cannot corroborate', async () => {
    transaction([near('user-1', 0), near('user-1'), near('user-1'), near('user-2')]);
    const result = await recordSeismicReport('user-1', report);
    expect(result.corroboratingDeviceCount).toBe(2);
    expect(result.corroborated).toBe(false);
  });

  it('ignores reports outside the 50 km radius', async () => {
    transaction([near('user-1', 0), near('user-2'), near('far-away', 2)]); // ~220 km north
    expect((await recordSeismicReport('user-1', report)).corroboratingDeviceCount).toBe(2);
  });

  it('alerts once when three distinct nearby devices agree', async () => {
    const query = transaction([near('user-1', 0), near('user-2'), near('user-3')]);
    const result = await recordSeismicReport('user-1', report);

    expect(result).toMatchObject({ corroboratingDeviceCount: 3, corroborated: true, alertSent: true });
    expect(query.mock.calls.some(([sql]) => sql.includes('INSERT INTO seismic_alerts'))).toBe(true);
    expect(mockNotify).toHaveBeenCalledWith({ latitude: 27.7172, longitude: 85.324, deviceCount: 3 });
  });

  it('does not alert again for an area already alerted within the cooldown', async () => {
    transaction([near('user-1', 0), near('user-2'), near('user-3'), near('user-4')], [KATHMANDU]);
    const result = await recordSeismicReport('user-4', report);
    expect(result).toMatchObject({ corroborated: true, alertSent: false });
    expect(mockNotify).not.toHaveBeenCalled();
  });

  it('a push failure does not fail the report', async () => {
    mockNotify.mockRejectedValueOnce(new Error('fcm down'));
    transaction([near('user-1', 0), near('user-2'), near('user-3')]);
    await expect(recordSeismicReport('user-1', report)).resolves.toMatchObject({ alertSent: true });
  });
});

describe('haversineKm', () => {
  it('matches known distances', () => {
    expect(haversineKm(27.7172, 85.324, 27.7172, 85.324)).toBe(0);
    // Kathmandu → Pokhara ≈ 140 km
    expect(haversineKm(27.7172, 85.324, 28.2096, 83.9856)).toBeGreaterThan(130);
    expect(haversineKm(27.7172, 85.324, 28.2096, 83.9856)).toBeLessThan(150);
  });
});
