import { createHash } from 'node:crypto';

jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));

import { pool, withTransaction } from '../src/database/pool';
import { requestOtp, verifyOtp } from '../src/services/verificationService';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;

function hashOf(code: string): string {
  return createHash('sha256').update(code).digest('hex');
}

/** Mirrors moderationService.test.ts's own helper: mocks withTransaction
 * with a fake client whose query() resolves each call in the given order. */
function mockTransactionQueries(...responses: Array<{ rows: unknown[] }>) {
  const clientQuery = jest.fn();
  for (const response of responses) clientQuery.mockResolvedValueOnce(response);
  mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
    work({ query: clientQuery }),
  );
  return clientQuery;
}

function fakeAttemptRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'attempt-1',
    code_hash: hashOf('123456'),
    attempts: 0,
    max_attempts: 5,
    expires_at: new Date(Date.now() + 5 * 60_000),
    consumed_at: null,
    created_at: new Date(),
    ...overrides,
  };
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('requestOtp', () => {
  it('generates a cryptographically-random 6-digit numeric code', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] }); // cooldown check: no prior row
    mockPoolQuery.mockResolvedValueOnce({ rows: [] }); // insert

    const { code } = await requestOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', ipAddress: null });
    expect(code).toMatch(/^\d{6}$/);
  });

  it('stores only the SHA-256 hash of the code — never the raw code', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });

    const { code } = await requestOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', ipAddress: null });

    const [insertSql, insertParams] = mockPoolQuery.mock.calls[1];
    expect(insertSql).toMatch(/INSERT INTO verification_attempts/);
    expect(insertParams).not.toContain(code);
    expect(insertParams).toContain(hashOf(code));
  });

  it('sets a 5-minute expiry and max_attempts=5 on the new row', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });

    const before = Date.now();
    await requestOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', ipAddress: null });

    const [, insertParams] = mockPoolQuery.mock.calls[1];
    const [, , , , maxAttempts, expiresAt] = insertParams;
    expect(maxAttempts).toBe(5);
    const ttlMs = (expiresAt as Date).getTime() - before;
    expect(ttlMs).toBeGreaterThan(4.9 * 60_000);
    expect(ttlMs).toBeLessThanOrEqual(5.1 * 60_000);
  });

  it('rejects a new request within the 60-second resend cooldown', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ created_at: new Date(Date.now() - 10_000) }] });

    await expect(
      requestOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', ipAddress: null }),
    ).rejects.toThrow(/wait/i);
  });

  it('allows a new request once the resend cooldown has elapsed', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [{ created_at: new Date(Date.now() - 61_000) }] });
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });

    const { code } = await requestOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', ipAddress: null });
    expect(code).toMatch(/^\d{6}$/);
  });
});

describe('verifyOtp', () => {
  it('returns invalid when no verification row exists (never reveals "no such request")', async () => {
    mockTransactionQueries({ rows: [] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(result.outcome).toBe('invalid');
  });

  it('verifies a correct code and marks it consumed (single-use)', async () => {
    const clientQuery = mockTransactionQueries({ rows: [fakeAttemptRow()] }, { rows: [] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });

    expect(result.outcome).toBe('verified');
    expect(clientQuery.mock.calls[1][0]).toMatch(/UPDATE verification_attempts SET consumed_at = now\(\)/);
    expect(clientQuery.mock.calls[1][1]).toEqual(['attempt-1']);
  });

  it('rejects a wrong code with the SAME generic outcome and increments attempts', async () => {
    const clientQuery = mockTransactionQueries({ rows: [fakeAttemptRow()] }, { rows: [] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '999999' });

    expect(result.outcome).toBe('invalid');
    const [updateSql, updateParams] = clientQuery.mock.calls[1];
    expect(updateSql).toMatch(/UPDATE verification_attempts/);
    expect(updateParams).toEqual([1, false, 'attempt-1']);
  });

  it('replay protection: rejects an already-consumed code even if it matches', async () => {
    mockTransactionQueries({ rows: [fakeAttemptRow({ consumed_at: new Date() })] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(result.outcome).toBe('invalid');
  });

  it('rejects an expired code even if it matches', async () => {
    mockTransactionQueries({ rows: [fakeAttemptRow({ expires_at: new Date(Date.now() - 1000) })] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(result.outcome).toBe('invalid');
  });

  it('rejects once attempts are already exhausted, even with the correct code', async () => {
    mockTransactionQueries({ rows: [fakeAttemptRow({ attempts: 5, max_attempts: 5 })] });
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(result.outcome).toBe('invalid');
  });

  it('consumes the row once the max-attempts wrong-guess threshold is reached', async () => {
    const clientQuery = mockTransactionQueries(
      { rows: [fakeAttemptRow({ attempts: 4, max_attempts: 5 })] },
      { rows: [] },
    );
    const result = await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '999999' });

    expect(result.outcome).toBe('invalid');
    const [, updateParams] = clientQuery.mock.calls[1];
    // [newAttempts=5, exhausted=true, id] — exhausted flips consumed_at on
    // this final wrong guess, permanently locking this row out.
    expect(updateParams).toEqual([5, true, 'attempt-1']);
  });

  it('locks the candidate row with SELECT ... FOR UPDATE (transaction-safe against concurrent verification)', async () => {
    const clientQuery = mockTransactionQueries({ rows: [] });
    await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(clientQuery.mock.calls[0][0]).toMatch(/FOR UPDATE/);
  });

  it('only ever considers the MOST RECENT row for the target (a resend invalidates older codes)', async () => {
    const clientQuery = mockTransactionQueries({ rows: [] });
    await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(clientQuery.mock.calls[0][0]).toMatch(/ORDER BY created_at DESC LIMIT 1/);
  });

  // withTransaction (database/pool.ts) wraps this whole flow in a real
  // Postgres transaction with a row-level lock — two concurrent
  // verifyOtp() calls against the SAME row serialize on that lock (the
  // second blocks until the first's transaction commits, then re-reads
  // the now-consumed row and gets 'invalid'). That real concurrency
  // guarantee is a property of Postgres's FOR UPDATE semantics, verified
  // here structurally (the query text assertion above) rather than by a
  // live concurrent-DB integration test — consistent with this project's
  // existing convention of mocking pool/withTransaction in unit tests
  // (see moderationService.test.ts) and disclosing, not silently
  // skipping, what a live-Postgres run would additionally confirm.
  it('is scoped to run entirely inside one withTransaction call (never issues two separate transactions for one verify)', async () => {
    mockTransactionQueries({ rows: [fakeAttemptRow()] }, { rows: [] });
    await verifyOtp({ channel: 'sms', target: '+9779812345678', purpose: 'login', code: '123456' });
    expect(mockWithTransaction).toHaveBeenCalledTimes(1);
  });
});
