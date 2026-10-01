jest.mock('../src/database/pool', () => ({ pool: { query: jest.fn() }, withTransaction: jest.fn() }));

import { pool } from '../src/database/pool';
import { listActiveAlerts, updateAlert } from '../src/services/alertService';
import { ingestFromAdapter, registeredAdapters, type DisasterSourceAdapter } from '../src/services/disasterSources';

const mockQuery = pool.query as jest.Mock;
const row = (o: Record<string, unknown> = {}) => ({
  id: 'a1', source_type: 'official', source_name: 'Authority', category: 'flood', severity: 'warning',
  status: 'active', title: 'Flood', body: 'b', instructions: null, latitude: 27.7, longitude: 85.3, radius_km: 5,
  province: null, district: null, municipality: null, issued_at: new Date(), expires_at: null, resolved_at: null,
  updated_at: new Date(), ...o,
});

beforeEach(() => jest.clearAllMocks());

describe('alertService', () => {
  it('lists only active, unexpired alerts, most severe first', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] });
    const alerts = await listActiveAlerts();
    const sql = mockQuery.mock.calls[0][0] as string;
    expect(sql).toMatch(/status = 'active'/);
    expect(sql).toMatch(/expires_at IS NULL OR expires_at > now\(\)/);
    expect(alerts[0]).toMatchObject({ sourceType: 'official', area: { radiusKm: 5 } });
  });

  it('a resolved alert cannot be edited, only its status changed', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row({ status: 'resolved' })] });
    await expect(updateAlert('a1', { title: 'New' })).rejects.toMatchObject({ status: 409 });
  });

  it('resolving stamps resolved_at', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] }).mockResolvedValueOnce({ rows: [row({ status: 'resolved' })] });
    await updateAlert('a1', { status: 'resolved' });
    const params = mockQuery.mock.calls[1][1] as unknown[];
    expect(params[8]).toBe('resolved');
    expect(params[9]).toBe(true);
  });
});

describe('disaster source adapters', () => {
  const adapter = (items: unknown[]): DisasterSourceAdapter => ({
    sourceName: 'Test Authority Feed',
    sourceType: 'official',
    fetchAlerts: async () => items as never,
  });
  const valid = { externalId: 'x-1', category: 'flood', severity: 'warning', title: 'Flood', body: 'b', province: 'Koshi' };

  it('stamps the adapter\'s own source on every alert and upserts by external id', async () => {
    mockQuery.mockResolvedValue({ rows: [] });
    const result = await ingestFromAdapter(adapter([valid]));
    expect(result).toEqual({ upserted: 1, rejected: 0 });
    const [sql, params] = mockQuery.mock.calls[0] as [string, unknown[]];
    expect(sql).toMatch(/ON CONFLICT \(source_name, external_id\)/);
    expect(params.slice(0, 3)).toEqual(['official', 'Test Authority Feed', 'x-1']);
  });

  it('a feed item cannot override its source', async () => {
    mockQuery.mockResolvedValue({ rows: [] });
    await ingestFromAdapter(adapter([{ ...valid, sourceType: 'community', sourceName: 'Someone else' }]));
    expect((mockQuery.mock.calls[0][1] as unknown[]).slice(0, 2)).toEqual(['official', 'Test Authority Feed']);
  });

  it('rejects malformed items without storing them', async () => {
    const result = await ingestFromAdapter(adapter([{ ...valid, severity: 'extreme' }, { ...valid, province: undefined }]));
    expect(result).toEqual({ upserted: 0, rejected: 2 });
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('an item the source marks as ended is stored resolved', async () => {
    mockQuery.mockResolvedValue({ rows: [] });
    await ingestFromAdapter(adapter([{ ...valid, ended: true }]));
    expect((mockQuery.mock.calls[0][1] as unknown[])[5]).toBe('resolved');
  });

  it('no unverified source is registered', () => {
    expect(registeredAdapters).toEqual([]);
  });
});
