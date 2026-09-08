import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';

jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import { env } from '../src/config/env';
import {
  hashEmployeePassword,
  issueEmployeeSession,
  loginEmployee,
  revokeEmployeeRefreshToken,
  rotateEmployeeRefreshToken,
  verifyEmployeeAccessToken,
} from '../src/services/employeeAuthService';
import { verifyAccessToken } from '../src/services/sessionService';

const mockedQuery = pool.query as jest.Mock;

function fakeEmployeeRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'employee-1',
    email: 'staff@example.com',
    password_hash: '',
    display_name: 'Staff Member',
    role: 'employee',
    status: 'active',
    created_at: new Date('2026-01-01T00:00:00Z'),
    updated_at: new Date('2026-01-01T00:00:00Z'),
    last_login_at: null,
    ...overrides,
  };
}

describe('issueEmployeeSession', () => {
  it('signs an access token with kind:employee and inserts a hashed refresh token row into employee_sessions', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });

    const session = await issueEmployeeSession('employee-1', { userAgent: 'jest', ipAddress: '127.0.0.1' });

    const decoded = jwt.verify(session.accessToken, env.EMPLOYEE_JWT_ACCESS_SECRET) as {
      sub: string;
      kind: string;
    };
    expect(decoded.sub).toBe('employee-1');
    expect(decoded.kind).toBe('employee');

    const [sql, params] = mockedQuery.mock.calls[0];
    expect(sql).toMatch(/INSERT INTO employee_sessions/);
    expect(params[0]).toBe('employee-1');
    expect(params[1]).not.toBe(session.refreshToken); // raw token never persisted
    expect(params[1]).toHaveLength(64); // sha256 hex digest
  });
});

describe('verifyEmployeeAccessToken', () => {
  it('returns the employee id for a valid token', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    const session = await issueEmployeeSession('employee-2', { userAgent: null, ipAddress: null });
    expect(verifyEmployeeAccessToken(session.accessToken)).toBe('employee-2');
  });

  it('rejects a token signed with the consumer-user JWT secret (separate identity spaces)', () => {
    const userToken = jwt.sign({ sub: 'employee-1' }, env.JWT_ACCESS_SECRET);
    expect(() => verifyEmployeeAccessToken(userToken)).toThrow(/Invalid or expired employee session token/);
  });

  it('rejects a malformed token', () => {
    expect(() => verifyEmployeeAccessToken('not-a-jwt')).toThrow(/Invalid or expired employee session token/);
  });

  it('rejects an expired token', () => {
    const expired = jwt.sign({ sub: 'employee-1', kind: 'employee' }, env.EMPLOYEE_JWT_ACCESS_SECRET, {
      expiresIn: '-1s',
    });
    expect(() => verifyEmployeeAccessToken(expired)).toThrow(/Invalid or expired employee session token/);
  });

  // Phase 19 security audit: algorithms is now pinned to ['HS256']
  // explicitly on verify — these prove that pin actually does something.
  it('rejects an unsigned ("alg: none") token even with a correct-looking payload', () => {
    const noneAlgToken = jwt.sign({ sub: 'employee-1', kind: 'employee' }, '', { algorithm: 'none' });
    expect(() => verifyEmployeeAccessToken(noneAlgToken)).toThrow(/Invalid or expired employee session token/);
  });

  it('rejects a token signed with the right secret but a different HMAC algorithm (HS384)', () => {
    const wrongAlg = jwt.sign({ sub: 'employee-1', kind: 'employee' }, env.EMPLOYEE_JWT_ACCESS_SECRET, {
      algorithm: 'HS384',
    });
    expect(() => verifyEmployeeAccessToken(wrongAlg)).toThrow(/Invalid or expired employee session token/);
  });
});

describe('a valid employee access token can never be verified as a consumer user token, or vice versa', () => {
  it('an employee session token fails requireAuth-style verifyAccessToken', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    const employeeSession = await issueEmployeeSession('employee-1', { userAgent: null, ipAddress: null });
    expect(() => verifyAccessToken(employeeSession.accessToken)).toThrow(/Invalid or expired session token/);
  });
});

describe('loginEmployee', () => {
  it('returns null for an unknown email without ever touching bcrypt', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] }); // getEmployeeByEmailWithPasswordHash
    const result = await loginEmployee('nobody@example.com', 'whatever12345', {
      userAgent: null,
      ipAddress: null,
    });
    expect(result).toBeNull();
  });

  it('returns null for a disabled account, even with the correct password', async () => {
    const passwordHash = await bcrypt.hash('correct-horse-battery', 10);
    mockedQuery.mockResolvedValueOnce({ rows: [fakeEmployeeRow({ password_hash: passwordHash, status: 'disabled' })] });

    const result = await loginEmployee('staff@example.com', 'correct-horse-battery', {
      userAgent: null,
      ipAddress: null,
    });
    expect(result).toBeNull();
  });

  it('returns null for an incorrect password', async () => {
    const passwordHash = await bcrypt.hash('correct-horse-battery', 10);
    mockedQuery.mockResolvedValueOnce({ rows: [fakeEmployeeRow({ password_hash: passwordHash })] });

    const result = await loginEmployee('staff@example.com', 'wrong-password', { userAgent: null, ipAddress: null });
    expect(result).toBeNull();
  });

  it('succeeds for the correct password on an active account, touches last_login, and issues a session', async () => {
    const passwordHash = await bcrypt.hash('correct-horse-battery', 10);
    mockedQuery
      .mockResolvedValueOnce({ rows: [fakeEmployeeRow({ password_hash: passwordHash })] }) // lookup
      .mockResolvedValueOnce({ rows: [] }) // touchEmployeeLastLogin
      .mockResolvedValueOnce({ rows: [] }); // issueEmployeeSession insert

    const result = await loginEmployee('staff@example.com', 'correct-horse-battery', {
      userAgent: 'jest',
      ipAddress: '127.0.0.1',
    });

    expect(result).not.toBeNull();
    expect(result!.employee.id).toBe('employee-1');
    expect(result!.employee).not.toHaveProperty('password_hash' as never);
    expect(mockedQuery.mock.calls[1][0]).toMatch(/UPDATE employees SET last_login_at/);
  });
});

describe('hashEmployeePassword', () => {
  it('produces a hash bcrypt.compare accepts for the original password', async () => {
    const hash = await hashEmployeePassword('a-reasonably-long-password');
    expect(await bcrypt.compare('a-reasonably-long-password', hash)).toBe(true);
    expect(await bcrypt.compare('wrong', hash)).toBe(false);
  });
});

describe('rotateEmployeeRefreshToken', () => {
  it('rejects an unknown/expired/revoked refresh token', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    await expect(
      rotateEmployeeRefreshToken('does-not-exist', { userAgent: null, ipAddress: null }),
    ).rejects.toThrow(/Invalid or expired refresh token/);
  });

  it('revokes the old session and issues a new pair on success', async () => {
    mockedQuery
      .mockResolvedValueOnce({ rows: [{ id: 'session-1', employee_id: 'employee-5' }] }) // lookup
      .mockResolvedValueOnce({ rows: [] }) // revoke UPDATE
      .mockResolvedValueOnce({ rows: [] }); // new session INSERT

    const session = await rotateEmployeeRefreshToken('some-refresh-token', { userAgent: null, ipAddress: null });

    expect(mockedQuery.mock.calls[1][0]).toMatch(/UPDATE employee_sessions SET revoked_at/);
    const decoded = jwt.verify(session.accessToken, env.EMPLOYEE_JWT_ACCESS_SECRET) as { sub: string };
    expect(decoded.sub).toBe('employee-5');
  });
});

describe('revokeEmployeeRefreshToken', () => {
  it('issues an UPDATE keyed on the token hash, scoped to employee_sessions', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    await revokeEmployeeRefreshToken('some-token');
    expect(mockedQuery.mock.calls[0][0]).toMatch(/UPDATE employee_sessions SET revoked_at/);
    expect(mockedQuery.mock.calls[0][1][0]).toHaveLength(64);
  });
});
