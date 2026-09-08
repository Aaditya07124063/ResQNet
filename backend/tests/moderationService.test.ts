jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import {
  getReviewCaseWithReports,
  listReviewCases,
  takeModerationAction,
} from '../src/services/moderationService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;

function fakeCaseRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'case-1',
    target_user_id: 'target-1',
    status: 'open',
    trigger_reason: 'report_threshold',
    report_count_at_open: 3,
    opened_at: new Date('2026-01-01T00:00:00Z'),
    closed_at: null,
    closed_by_employee_id: null,
    ...overrides,
  };
}

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

function fakeActionRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'action-1',
    target_user_id: 'target-1',
    review_case_id: 'case-1',
    action_type: 'dismiss',
    performed_by_employee_id: 'employee-1',
    reason: null,
    created_at: new Date('2026-01-02T00:00:00Z'),
    ...overrides,
  };
}

/** Mocks withTransaction with a fake client whose query() resolves each
 * call in the given order — mirrors the exact sequence
 * takeModerationAction issues (lock select, insert action, [close update,
 * resolve-reports update], [account_status update]). */
function mockTransactionQueries(...responses: Array<{ rows: unknown[] }>) {
  const clientQuery = jest.fn();
  for (const response of responses) clientQuery.mockResolvedValueOnce(response);
  mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
    work({ query: clientQuery }),
  );
  return clientQuery;
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('listReviewCases', () => {
  it('lists all cases, newest first, when no status filter is given', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeCaseRow()] });
    const result = await listReviewCases();
    expect(result).toHaveLength(1);
    expect(mockPoolQuery.mock.calls[0][0]).not.toMatch(/WHERE/);
  });

  it('filters by status when given', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await listReviewCases('closed');
    expect(mockPoolQuery.mock.calls[0][0]).toMatch(/WHERE status = \$1/);
    expect(mockPoolQuery.mock.calls[0][1]).toEqual(['closed']);
  });
});

describe('getReviewCaseWithReports', () => {
  it('returns null for a nonexistent case, without querying reports at all', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    const result = await getReviewCaseWithReports('nonexistent');
    expect(result).toBeNull();
    expect(mockPoolQuery).toHaveBeenCalledTimes(1);
  });

  it('returns the case plus every report against its target — including reporterUserId (employee-only view)', async () => {
    mockPoolQuery
      .mockResolvedValueOnce({ rows: [fakeCaseRow()] })
      .mockResolvedValueOnce({ rows: [fakeReportRow()] });

    const result = await getReviewCaseWithReports('case-1');

    expect(result!.reviewCase.id).toBe('case-1');
    expect(result!.reports).toHaveLength(1);
    expect(result!.reports[0]).toMatchObject({ reporterUserId: 'reporter-1', reportedUserId: 'target-1' });
    expect(mockPoolQuery.mock.calls[1][1]).toEqual(['target-1']); // scoped by target, not case id (no FK exists)
  });
});

describe('takeModerationAction', () => {
  const INPUT = { actionType: 'dismiss' as const, reason: 'no violation found' };

  it('locks the case row with SELECT ... FOR UPDATE', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow()] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
    );
    await takeModerationAction('case-1', 'employee-1', INPUT);
    expect(clientQuery.mock.calls[0][0]).toMatch(/FOR UPDATE/);
  });

  it('404s when the review case does not exist', async () => {
    mockTransactionQueries({ rows: [] });
    await expect(takeModerationAction('nonexistent', 'employee-1', INPUT)).rejects.toMatchObject({ status: 404 });
  });

  it('409s (conflict) when the review case is already closed — covers both a stale re-submit and a genuine duplicate action', async () => {
    mockTransactionQueries({ rows: [fakeCaseRow({ status: 'closed' })] });
    await expect(takeModerationAction('case-1', 'employee-1', INPUT)).rejects.toMatchObject({ status: 409 });
  });

  it('dismiss: closes the case, marks open reports "dismissed", never touches account_status', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ action_type: 'dismiss' })] },
      { rows: [fakeCaseRow({ status: 'closed', closed_by_employee_id: 'employee-1' })] },
      { rows: [] },
    );

    const result = await takeModerationAction('case-1', 'employee-1', { actionType: 'dismiss', reason: 'no violation' });

    expect(result.reviewCase.status).toBe('closed');
    expect(clientQuery.mock.calls[2][0]).toMatch(/UPDATE review_cases SET status = 'closed'/);
    expect(clientQuery.mock.calls[3][0]).toMatch(/UPDATE user_reports/);
    expect(clientQuery.mock.calls[3][1]).toEqual(['dismissed', 'no violation', 'employee-1', 'target-1']);
    expect(clientQuery.mock.calls).toHaveLength(4); // no users UPDATE at all
  });

  it('warn: closes the case, marks open reports "actioned", never touches account_status', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ action_type: 'warn' })] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
    );

    await takeModerationAction('case-1', 'employee-1', { actionType: 'warn', reason: 'first warning' });

    expect(clientQuery.mock.calls[3][1]).toEqual(['actioned', 'first warning', 'employee-1', 'target-1']);
    expect(clientQuery.mock.calls).toHaveLength(4);
  });

  it.each(['suspend_temporary', 'suspend_permanent'] as const)(
    '%s: closes the case, resolves reports, AND sets account_status = suspended',
    async (actionType) => {
      const clientQuery = mockTransactionQueries(
        { rows: [fakeCaseRow()] },
        { rows: [fakeActionRow({ action_type: actionType })] },
        { rows: [fakeCaseRow({ status: 'closed' })] },
        { rows: [] },
        { rows: [] },
      );

      await takeModerationAction('case-1', 'employee-1', { actionType, reason: 'policy violation' });

      expect(clientQuery.mock.calls[4][0]).toMatch(/UPDATE users SET account_status = \$1/);
      expect(clientQuery.mock.calls[4][1]).toEqual(['suspended', 'target-1']);
    },
  );

  // Phase 19 security audit: a later, less-severe action (on a NEW review
  // case opened after an earlier one already soft-deleted this target)
  // must never downgrade account_status back from 'deleted' to
  // 'suspended' — the SQL itself must guard this, not just application
  // logic, since nothing else re-checks the account's current status
  // before this UPDATE runs.
  it('never downgrades an already-deleted account back to suspended — the UPDATE guards account_status != \'deleted\' in SQL', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ action_type: 'suspend_permanent' })] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
      { rows: [] },
    );

    await takeModerationAction('case-1', 'employee-1', { actionType: 'suspend_permanent', reason: 'new incident' });

    expect(clientQuery.mock.calls[4][0]).toMatch(/account_status != 'deleted'/);
  });

  it('delete: closes the case, resolves reports, and sets account_status = deleted (soft marker, never a physical row DELETE)', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ action_type: 'delete' })] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
      { rows: [] },
    );

    await takeModerationAction('case-1', 'employee-1', { actionType: 'delete', reason: 'severe violation' });

    expect(clientQuery.mock.calls[4][1]).toEqual(['deleted', 'target-1']);
    expect(clientQuery.mock.calls.some((c) => /^\s*DELETE/i.test(c[0]))).toBe(false);
  });

  it('escalate: records the action but does NOT close the case, resolve reports, or touch account_status', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ action_type: 'escalate' })] },
    );

    const result = await takeModerationAction('case-1', 'employee-1', { actionType: 'escalate', reason: 'needs senior review' });

    expect(result.reviewCase.status).toBe('open'); // unchanged
    expect(clientQuery).toHaveBeenCalledTimes(2); // lock select + insert action ONLY
  });

  it('records the acting employee id from the parameter, never anything client-supplied embedded in input', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow()] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
    );
    await takeModerationAction('case-1', 'real-session-employee', INPUT);
    expect(clientQuery.mock.calls[1][1]).toEqual(['target-1', 'case-1', 'dismiss', 'real-session-employee', 'no violation found']);
  });

  it('a SQL-injection-shaped reason string is passed as a bound parameter, never concatenated into the query', async () => {
    const injection = "x'; DROP TABLE users; --";
    const clientQuery = mockTransactionQueries(
      { rows: [fakeCaseRow()] },
      { rows: [fakeActionRow({ reason: injection })] },
      { rows: [fakeCaseRow({ status: 'closed' })] },
      { rows: [] },
    );
    await takeModerationAction('case-1', 'employee-1', { actionType: 'dismiss', reason: injection });
    expect(clientQuery.mock.calls[1][1]).toContain(injection);
    expect(clientQuery.mock.calls[1][0]).not.toContain(injection); // never in the SQL text itself
  });
});
