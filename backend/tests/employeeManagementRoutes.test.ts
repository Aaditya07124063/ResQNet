import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({
  verifyEmployeeAccessToken: jest.fn(),
  hashEmployeePassword: jest.fn(),
}));
jest.mock('../src/services/employeeService', () => ({
  getEmployeeById: jest.fn(),
  createEmployee: jest.fn(),
  listEmployees: jest.fn(),
}));
jest.mock('../src/services/employeePermissionService', () => ({
  hasPermission: jest.fn(),
  listPermissions: jest.fn(),
  grantPermission: jest.fn(),
  revokePermission: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyEmployeeAccessToken, hashEmployeePassword } from '../src/services/employeeAuthService';
import { createEmployee, getEmployeeById, listEmployees } from '../src/services/employeeService';
import {
  grantPermission,
  hasPermission,
  listPermissions,
  revokePermission,
} from '../src/services/employeePermissionService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const app = createApp();

const ADMIN_ID = '11111111-1111-1111-1111-111111111111';
const TARGET_ID = '22222222-2222-2222-2222-222222222222';

const adminEmployee: AuthenticatedEmployee = {
  id: ADMIN_ID,
  email: 'admin@example.com',
  displayName: 'Admin',
  role: 'admin',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

function authenticateAs(employee: AuthenticatedEmployee, permitted: boolean) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
  (hasPermission as jest.Mock).mockResolvedValue(permitted);
}

describe('GET /api/v1/employee/employees', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/employee/employees');
    expect(res.status).toBe(401);
    expect(listEmployees).not.toHaveBeenCalled();
  });

  it('denies an authenticated employee lacking EMPLOYEE_MANAGE', async () => {
    authenticateAs({ ...adminEmployee, role: 'employee' }, false);
    const res = await request(app).get('/api/v1/employee/employees').set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(listEmployees).not.toHaveBeenCalled();
  });

  it('allows a permitted employee and never exposes password_hash', async () => {
    authenticateAs(adminEmployee, true);
    (listEmployees as jest.Mock).mockResolvedValue([adminEmployee]);
    const res = await request(app).get('/api/v1/employee/employees').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.employees[0]).not.toHaveProperty('password_hash' as never);
  });

  it('super_admin bypasses the permission check entirely (hasPermission short-circuits true)', async () => {
    authenticateAs({ ...adminEmployee, role: 'super_admin' }, true);
    (listEmployees as jest.Mock).mockResolvedValue([]);
    const res = await request(app).get('/api/v1/employee/employees').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
  });
});

describe('POST /api/v1/employee/employees', () => {
  const VALID_BODY = { email: 'new@example.com', password: 'a-long-enough-password', displayName: 'New Person', role: 'employee' };

  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/employee/employees').send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(createEmployee).not.toHaveBeenCalled();
  });

  it('denies an authenticated employee lacking EMPLOYEE_MANAGE', async () => {
    authenticateAs({ ...adminEmployee, role: 'employee' }, false);
    const res = await request(app).post('/api/v1/employee/employees').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(403);
    expect(createEmployee).not.toHaveBeenCalled();
  });

  it('rejects a password shorter than the policy minimum (12 chars)', async () => {
    authenticateAs(adminEmployee, true);
    const res = await request(app)
      .post('/api/v1/employee/employees')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, password: 'short' });
    expect(res.status).toBe(400);
    expect(createEmployee).not.toHaveBeenCalled();
  });

  it('rejects an invalid role not in the schema CHECK constraint', async () => {
    authenticateAs(adminEmployee, true);
    const res = await request(app)
      .post('/api/v1/employee/employees')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, role: 'super_user' });
    expect(res.status).toBe(400);
    expect(createEmployee).not.toHaveBeenCalled();
  });

  it('hashes the password before storage — the plaintext never reaches createEmployee', async () => {
    authenticateAs(adminEmployee, true);
    (hashEmployeePassword as jest.Mock).mockResolvedValue('bcrypt-hash-output');
    (createEmployee as jest.Mock).mockResolvedValue({ ...adminEmployee, id: TARGET_ID, role: 'employee' });

    await request(app).post('/api/v1/employee/employees').set('Authorization', 'Bearer t').send(VALID_BODY);

    expect(hashEmployeePassword).toHaveBeenCalledWith(VALID_BODY.password);
    expect((createEmployee as jest.Mock).mock.calls[0][0]).toMatchObject({ passwordHash: 'bcrypt-hash-output' });
    expect((createEmployee as jest.Mock).mock.calls[0][0]).not.toHaveProperty('password');
  });

  it('never echoes password_hash in the response', async () => {
    authenticateAs(adminEmployee, true);
    (hashEmployeePassword as jest.Mock).mockResolvedValue('bcrypt-hash-output');
    (createEmployee as jest.Mock).mockResolvedValue({ ...adminEmployee, id: TARGET_ID });
    const res = await request(app).post('/api/v1/employee/employees').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(201);
    expect(res.body.employee).not.toHaveProperty('password_hash' as never);
  });

  it('maps a duplicate-email unique violation to a safe 409', async () => {
    authenticateAs(adminEmployee, true);
    (hashEmployeePassword as jest.Mock).mockResolvedValue('bcrypt-hash-output');
    (createEmployee as jest.Mock).mockRejectedValue(Object.assign(new Error('duplicate'), { code: '23505' }));
    const res = await request(app).post('/api/v1/employee/employees').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(409);
  });
});

describe('POST/DELETE /api/v1/employee/employees/:id/permissions', () => {
  it('denies granting without EMPLOYEE_MANAGE', async () => {
    authenticateAs({ ...adminEmployee, role: 'employee' }, false);
    const res = await request(app)
      .post(`/api/v1/employee/employees/${TARGET_ID}/permissions`)
      .set('Authorization', 'Bearer t')
      .send({ permission: 'USER_VIEW' });
    expect(res.status).toBe(403);
    expect(grantPermission).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID target id', async () => {
    authenticateAs(adminEmployee, true);
    const res = await request(app)
      .post('/api/v1/employee/employees/not-a-uuid/permissions')
      .set('Authorization', 'Bearer t')
      .send({ permission: 'USER_VIEW' });
    expect(res.status).toBe(400);
    expect(grantPermission).not.toHaveBeenCalled();
  });

  it('grants a permission, attributing grantedByEmployeeId to the session identity (never client-supplied)', async () => {
    authenticateAs(adminEmployee, true);
    (listPermissions as jest.Mock).mockResolvedValue([]);
    await request(app)
      .post(`/api/v1/employee/employees/${TARGET_ID}/permissions`)
      .set('Authorization', 'Bearer t')
      .send({ permission: 'USER_VIEW', grantedByEmployeeId: 'attacker-controlled' });

    expect((grantPermission as jest.Mock).mock.calls[0]).toEqual([TARGET_ID, 'USER_VIEW', ADMIN_ID]);
  });

  it('revokes a permission', async () => {
    authenticateAs(adminEmployee, true);
    const res = await request(app)
      .delete(`/api/v1/employee/employees/${TARGET_ID}/permissions/USER_VIEW`)
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(204);
    expect(revokePermission).toHaveBeenCalledWith(TARGET_ID, 'USER_VIEW');
  });

  it('denies revoking without EMPLOYEE_MANAGE', async () => {
    authenticateAs({ ...adminEmployee, role: 'employee' }, false);
    const res = await request(app)
      .delete(`/api/v1/employee/employees/${TARGET_ID}/permissions/USER_VIEW`)
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(revokePermission).not.toHaveBeenCalled();
  });
});
