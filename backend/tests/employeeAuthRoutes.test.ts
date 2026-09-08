import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({
  loginEmployee: jest.fn(),
  rotateEmployeeRefreshToken: jest.fn(),
  revokeEmployeeRefreshToken: jest.fn(),
  verifyEmployeeAccessToken: jest.fn(),
}));
jest.mock('../src/services/employeeService', () => ({
  getEmployeeById: jest.fn(),
}));
jest.mock('../src/services/employeePermissionService', () => ({
  listPermissions: jest.fn(),
  hasPermission: jest.fn(),
}));

import { createApp } from '../src/app';
import {
  loginEmployee,
  revokeEmployeeRefreshToken,
  rotateEmployeeRefreshToken,
  verifyEmployeeAccessToken,
} from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { listPermissions } from '../src/services/employeePermissionService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const app = createApp();

const EMPLOYEE_ID = '11111111-1111-1111-1111-111111111111';

const activeEmployee: AuthenticatedEmployee = {
  id: EMPLOYEE_ID,
  email: 'staff@example.com',
  displayName: 'Staff Member',
  role: 'employee',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

function authenticateAs(employee: AuthenticatedEmployee) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
}

describe('POST /api/v1/employee/auth/login', () => {
  it('rejects a missing password', async () => {
    const res = await request(app).post('/api/v1/employee/auth/login').send({ email: 'a@example.com' });
    expect(res.status).toBe(400);
    expect(loginEmployee).not.toHaveBeenCalled();
  });

  it('rejects a malformed email', async () => {
    const res = await request(app)
      .post('/api/v1/employee/auth/login')
      .send({ email: 'not-an-email', password: 'whatever12345' });
    expect(res.status).toBe(400);
    expect(loginEmployee).not.toHaveBeenCalled();
  });

  it('returns a generic 401 for invalid credentials, never revealing whether the email exists', async () => {
    (loginEmployee as jest.Mock).mockResolvedValue(null);
    const res = await request(app)
      .post('/api/v1/employee/auth/login')
      .send({ email: 'nobody@example.com', password: 'whatever12345' });
    expect(res.status).toBe(401);
    expect(res.body.error.message).not.toMatch(/exist|found|disabled/i);
  });

  it('logs in successfully and never echoes password_hash', async () => {
    (loginEmployee as jest.Mock).mockResolvedValue({
      employee: activeEmployee,
      session: {
        accessToken: 'access-1',
        accessTokenExpiresAt: new Date('2026-01-01T00:15:00Z'),
        refreshToken: 'refresh-1',
        refreshTokenExpiresAt: new Date('2026-01-31T00:00:00Z'),
      },
    });

    const res = await request(app)
      .post('/api/v1/employee/auth/login')
      .send({ email: 'staff@example.com', password: 'correct-horse-battery' });

    expect(res.status).toBe(200);
    expect(res.body.employee.id).toBe(EMPLOYEE_ID);
    expect(res.body.employee).not.toHaveProperty('password_hash' as never);
    expect(res.body.session.accessToken).toBe('access-1');
  });

});

describe('POST /api/v1/employee/auth/refresh', () => {
  it('rejects a missing refreshToken', async () => {
    const res = await request(app).post('/api/v1/employee/auth/refresh').send({});
    expect(res.status).toBe(400);
  });

  it('propagates an invalid-refresh-token error as 401', async () => {
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (rotateEmployeeRefreshToken as jest.Mock).mockRejectedValue(HttpError.unauthorized('Invalid or expired refresh token'));
    const res = await request(app)
      .post('/api/v1/employee/auth/refresh')
      .send({ refreshToken: 'x'.repeat(30) });
    expect(res.status).toBe(401);
  });
});

describe('POST /api/v1/employee/auth/logout', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/employee/auth/logout').send({ refreshToken: 'x'.repeat(30) });
    expect(res.status).toBe(401);
    expect(revokeEmployeeRefreshToken).not.toHaveBeenCalled();
  });

  it('revokes for an authenticated employee', async () => {
    authenticateAs(activeEmployee);
    const res = await request(app)
      .post('/api/v1/employee/auth/logout')
      .set('Authorization', 'Bearer t')
      .send({ refreshToken: 'x'.repeat(30) });
    expect(res.status).toBe(204);
    expect(revokeEmployeeRefreshToken).toHaveBeenCalledWith('x'.repeat(30));
  });
});

describe('GET /api/v1/employee/me', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/employee/me');
    expect(res.status).toBe(401);
  });

  it('denies a normal consumer-user access token (different secret, different identity space)', async () => {
    // The mock for verifyEmployeeAccessToken always resolves via the
    // mocked module regardless of the actual bearer value in this test
    // file — this test instead documents the REAL cross-verification
    // behavior via employeeAuthService.test.ts. Here we simulate the
    // middleware's rejection path when verification throws, which is
    // exactly what a real consumer-user token does against the employee
    // secret in the unmocked service.
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (verifyEmployeeAccessToken as jest.Mock).mockImplementation(() => {
      throw HttpError.unauthorized('Invalid or expired employee session token');
    });
    const res = await request(app).get('/api/v1/employee/me').set('Authorization', 'Bearer some-user-token');
    expect(res.status).toBe(401);
  });

  it('returns the authenticated employee and their permissions', async () => {
    authenticateAs(activeEmployee);
    (listPermissions as jest.Mock).mockResolvedValue([
      { permission: 'USER_VIEW', grantedAt: '2026-01-01T00:00:00.000Z', grantedByEmployeeId: 'admin-1' },
    ]);

    const res = await request(app).get('/api/v1/employee/me').set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.employee.id).toBe(EMPLOYEE_ID);
    expect(res.body.employee).not.toHaveProperty('password_hash' as never);
    expect(res.body.permissions).toHaveLength(1);
  });

  it('a disabled employee is denied even with a structurally-valid token', async () => {
    (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(EMPLOYEE_ID);
    (getEmployeeById as jest.Mock).mockResolvedValue({ ...activeEmployee, status: 'disabled' });
    const res = await request(app).get('/api/v1/employee/me').set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
  });
});

// Placed last in the file: employeeAuthRateLimiter is shared (IP-keyed)
// across BOTH /login and /refresh, so exhausting its budget here must run
// after every other test in this file that hits either route from the
// same test-runner IP.
describe('employee auth rate limiting', () => {
  it('rate-limits repeated login attempts from the same IP', async () => {
    (loginEmployee as jest.Mock).mockResolvedValue(null);
    let lastStatus = 0;
    // EMPLOYEE_AUTH_RATE_LIMIT_MAX defaults to 10/window.
    for (let i = 0; i < 11; i++) {
      const res = await request(app)
        .post('/api/v1/employee/auth/login')
        .send({ email: `ratelimit-test-${i}@example.com`, password: 'whatever12345' });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});
