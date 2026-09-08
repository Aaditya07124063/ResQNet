jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import { createReport } from '../src/services/reportService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;

function fakeReportRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'report-1',
    reporter_user_id: 'reporter-1',
    reported_user_id: 'target-1',
    reason: 'harassment',
    description: null,
    status: 'open',
    resolution: null,
    resolved_by_employee_id: null,
    resolved_at: null,
    created_at: new Date('2026-01-01T00:00:00Z'),
    ...overrides,
  };
}

const INPUT = { reportedUserId: 'target-1', reason: 'harassment', description: null };

beforeEach(() => {
  // Default: the review-case side-effect step finds no configured
  // threshold (empty settings row set) unless a test overrides this.
  mockWithTransaction.mockImplementation(async (work: (client: { query: jest.Mock }) => unknown) =>
    work({ query: jest.fn().mockResolvedValue({ rows: [] }) }),
  );
});

describe('createReport', () => {
  it('rejects a self-report before ever touching the database', async () => {
    await expect(createReport('user-1', { ...INPUT, reportedUserId: 'user-1' })).rejects.toMatchObject({
      status: 400,
    });
    expect(mockPoolQuery).not.toHaveBeenCalled();
  });

  it('creates a report and returns a minimal shape that never echoes the reporter id', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
    const result = await createReport('reporter-1', INPUT);
    expect(result).toEqual({
      id: 'report-1',
      reportedUserId: 'target-1',
      reason: 'harassment',
      description: null,
      status: 'open',
      createdAt: '2026-01-01T00:00:00.000Z',
    });
    expect(result).not.toHaveProperty('reporterUserId');
  });

  it('maps a duplicate-open-report unique violation to a safe 409, never the raw DB error', async () => {
    mockPoolQuery.mockRejectedValueOnce(
      Object.assign(new Error('duplicate key value violates unique constraint "uq_user_reports_open_pair"'), {
        code: '23505',
      }),
    );
    await expect(createReport('reporter-1', INPUT)).rejects.toMatchObject({
      status: 409,
      code: 'CONFLICT',
    });
  });

  it('maps a foreign-key violation (nonexistent target) to a safe 400', async () => {
    mockPoolQuery.mockRejectedValueOnce(
      Object.assign(new Error('insert or update on table "user_reports" violates foreign key constraint'), {
        code: '23503',
      }),
    );
    await expect(createReport('reporter-1', INPUT)).rejects.toMatchObject({ status: 400 });
  });

  it('maps a check-violation (self-report reaching the DB) to a safe 400', async () => {
    mockPoolQuery.mockRejectedValueOnce(
      Object.assign(new Error('violates check constraint "chk_user_reports_not_self"'), { code: '23514' }),
    );
    await expect(createReport('reporter-1', INPUT)).rejects.toMatchObject({ status: 400 });
  });

  it('propagates an unrecognized database failure rather than masking it as a report-specific error', async () => {
    mockPoolQuery.mockRejectedValueOnce(new Error('connection terminated unexpectedly'));
    await expect(createReport('reporter-1', INPUT)).rejects.toThrow('connection terminated unexpectedly');
  });

  it('still returns the successfully-created report even if the review-case evaluation step throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
    mockWithTransaction.mockRejectedValueOnce(new Error('admin_settings lookup failed'));
    const result = await createReport('reporter-1', INPUT);
    expect(result.id).toBe('report-1');
  });

  describe('review-case threshold behavior', () => {
    it('does nothing when no threshold is configured (never invents a fallback default)', async () => {
      mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
      const clientQuery = jest.fn().mockResolvedValueOnce({ rows: [] });
      mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
        work({ query: clientQuery }),
      );

      await createReport('reporter-1', INPUT);

      expect(clientQuery).toHaveBeenCalledTimes(1);
    });

    it('opens a review case and promotes account_status once the configured threshold is met', async () => {
      mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
      const clientQuery = jest
        .fn()
        .mockResolvedValueOnce({ rows: [{ key: 'report_threshold', value: 3 }] })
        .mockResolvedValueOnce({ rows: [{ count: '3' }] })
        .mockResolvedValueOnce({ rows: [] })
        .mockResolvedValueOnce({ rows: [] })
        .mockResolvedValueOnce({ rows: [] });
      mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
        work({ query: clientQuery }),
      );

      await createReport('reporter-1', INPUT);

      expect(clientQuery).toHaveBeenCalledTimes(5);
      expect(clientQuery.mock.calls[3]?.[0]).toMatch(/INSERT INTO review_cases/);
      expect(clientQuery.mock.calls[4]?.[0]).toMatch(/UPDATE users SET account_status = 'review_required'/);
    });

    it('does not open a second review case when one is already open for the target', async () => {
      mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
      const clientQuery = jest
        .fn()
        .mockResolvedValueOnce({ rows: [{ key: 'report_threshold', value: 3 }] })
        .mockResolvedValueOnce({ rows: [{ count: '5' }] })
        .mockResolvedValueOnce({ rows: [{ id: 'existing-case' }] });
      mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
        work({ query: clientQuery }),
      );

      await createReport('reporter-1', INPUT);

      expect(clientQuery).toHaveBeenCalledTimes(3);
    });

    it('does not open a review case when the open-report count is still below threshold', async () => {
      mockPoolQuery.mockResolvedValueOnce({ rows: [fakeReportRow()] });
      const clientQuery = jest
        .fn()
        .mockResolvedValueOnce({ rows: [{ key: 'report_threshold', value: 5 }] })
        .mockResolvedValueOnce({ rows: [{ count: '2' }] });
      mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
        work({ query: clientQuery }),
      );

      await createReport('reporter-1', INPUT);

      expect(clientQuery).toHaveBeenCalledTimes(2);
    });
  });
});
