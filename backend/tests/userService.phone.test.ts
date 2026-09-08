jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import { findOrCreateUserByPhone } from '../src/services/userService';

const mockQuery = pool.query as jest.Mock;

function dbUserRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'user-1',
    google_subject: null,
    email: null,
    email_verified: false,
    phone_number: '+9779812345678',
    phone_verified: false,
    display_name: null,
    account_status: 'active',
    created_at: new Date(),
    updated_at: new Date(),
    last_login_at: null,
    ...overrides,
  };
}

beforeEach(() => jest.clearAllMocks());

describe('findOrCreateUserByPhone', () => {
  it('creates a new user when the phone number does not exist, with phone_verified=true', async () => {
    mockQuery
      .mockResolvedValueOnce({ rows: [] }) // initial SELECT: not found
      .mockResolvedValueOnce({ rows: [] }) // INSERT
      .mockResolvedValueOnce({ rows: [dbUserRow({ phone_verified: true })] }); // follow-up SELECT

    const user = await findOrCreateUserByPhone('+9779812345678');

    expect(user.id).toBe('user-1');
    expect(user.phoneNumber).toBe('+9779812345678');
    expect(user.phoneVerified).toBe(true);
    const [insertSql, insertParams] = mockQuery.mock.calls[1];
    expect(insertSql).toMatch(/INSERT INTO users/);
    expect(insertSql).toMatch(/ON CONFLICT \(phone_number\) DO NOTHING/);
    expect(insertParams).toEqual(['+9779812345678']);
  });

  it('returns the existing user for an already-registered phone number without inserting a new row', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [dbUserRow({ phone_verified: true })] });

    const user = await findOrCreateUserByPhone('+9779812345678');

    expect(user.id).toBe('user-1');
    expect(mockQuery).toHaveBeenCalledTimes(1); // only the lookup SELECT — no INSERT/UPDATE needed
  });

  it('flips phone_verified to true for an existing-but-unverified row', async () => {
    mockQuery
      .mockResolvedValueOnce({ rows: [dbUserRow({ phone_verified: false })] }) // lookup: found, unverified
      .mockResolvedValueOnce({ rows: [] }); // UPDATE phone_verified

    const user = await findOrCreateUserByPhone('+9779812345678');

    expect(user.phoneVerified).toBe(true);
    const [updateSql, updateParams] = mockQuery.mock.calls[1];
    expect(updateSql).toMatch(/UPDATE users SET phone_verified = true/);
    expect(updateParams).toEqual(['user-1']);
  });

  it('does not create a duplicate row when losing the insert race to a concurrent request', async () => {
    mockQuery
      .mockResolvedValueOnce({ rows: [] }) // initial SELECT: not found
      .mockResolvedValueOnce({ rows: [] }) // INSERT (ON CONFLICT DO NOTHING no-ops)
      .mockResolvedValueOnce({ rows: [dbUserRow({ phone_verified: false })] }) // follow-up SELECT: the concurrent winner's row
      .mockResolvedValueOnce({ rows: [] }); // this request still marks it verified

    const user = await findOrCreateUserByPhone('+9779812345678');
    expect(user.id).toBe('user-1');
    expect(user.phoneVerified).toBe(true);
  });
});
