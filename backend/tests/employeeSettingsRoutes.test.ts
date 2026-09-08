import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({
  verifyEmployeeAccessToken: jest.fn(),
}));
jest.mock('../src/services/employeeService', () => ({
  getEmployeeById: jest.fn(),
}));
jest.mock('../src/services/employeePermissionService', () => ({
  hasPermission: jest.fn(),
}));
jest.mock('../src/services/adminSettingsService', () => ({
  listSettings: jest.fn(),
  getSetting: jest.fn(),
  upsertSetting: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import { getSetting, listSettings, upsertSetting } from '../src/services/adminSettingsService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const app = createApp();
const EMPLOYEE_ID = '11111111-1111-1111-1111-111111111111';

const employee: AuthenticatedEmployee = {
  id: EMPLOYEE_ID,
  email: 'admin@example.com',
  displayName: 'Admin',
  role: 'admin',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

function authenticateAs(permitted: boolean) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
  (hasPermission as jest.Mock).mockResolvedValue(permitted);
}

describe('GET /api/v1/employee/settings', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/employee/settings');
    expect(res.status).toBe(401);
  });

  it('denies without SETTINGS_MANAGE', async () => {
    authenticateAs(false);
    const res = await request(app).get('/api/v1/employee/settings').set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(listSettings).not.toHaveBeenCalled();
  });

  it('allows a permitted employee', async () => {
    authenticateAs(true);
    (listSettings as jest.Mock).mockResolvedValue([
      { key: 'report_threshold', value: 5, description: null, updatedAt: '2026-01-01T00:00:00.000Z', updatedByEmployeeId: EMPLOYEE_ID },
    ]);
    const res = await request(app).get('/api/v1/employee/settings').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.settings).toHaveLength(1);
  });
});

describe('GET /api/v1/employee/settings/:key', () => {
  it('404s for an unknown key', async () => {
    authenticateAs(true);
    (getSetting as jest.Mock).mockResolvedValue(null);
    const res = await request(app).get('/api/v1/employee/settings/nonexistent').set('Authorization', 'Bearer t');
    expect(res.status).toBe(404);
  });
});

describe('PUT /api/v1/employee/settings/:key', () => {
  it('denies without SETTINGS_MANAGE', async () => {
    authenticateAs(false);
    const res = await request(app)
      .put('/api/v1/employee/settings/report_threshold')
      .set('Authorization', 'Bearer t')
      .send({ value: 5 });
    expect(res.status).toBe(403);
    expect(upsertSetting).not.toHaveBeenCalled();
  });

  it('rejects a request body missing value entirely', async () => {
    authenticateAs(true);
    const res = await request(app)
      .put('/api/v1/employee/settings/report_threshold')
      .set('Authorization', 'Bearer t')
      .send({});
    expect(res.status).toBe(400);
    expect(upsertSetting).not.toHaveBeenCalled();
  });

  it('upserts, attributing updatedByEmployeeId to the session identity (never client-supplied)', async () => {
    authenticateAs(true);
    (upsertSetting as jest.Mock).mockResolvedValue({
      key: 'report_threshold',
      value: 5,
      description: null,
      updatedAt: '2026-01-01T00:00:00.000Z',
      updatedByEmployeeId: EMPLOYEE_ID,
    });

    const res = await request(app)
      .put('/api/v1/employee/settings/report_threshold')
      .set('Authorization', 'Bearer t')
      .send({ value: 5, updatedByEmployeeId: 'attacker-controlled' });

    expect(res.status).toBe(200);
    expect((upsertSetting as jest.Mock).mock.calls[0]).toEqual(['report_threshold', 5, null, EMPLOYEE_ID]);
  });

  it('accepts value: 0 (falsy but valid) without rejecting it as missing', async () => {
    authenticateAs(true);
    (upsertSetting as jest.Mock).mockResolvedValue({
      key: 'report_threshold',
      value: 0,
      description: null,
      updatedAt: '2026-01-01T00:00:00.000Z',
      updatedByEmployeeId: EMPLOYEE_ID,
    });
    const res = await request(app)
      .put('/api/v1/employee/settings/report_threshold')
      .set('Authorization', 'Bearer t')
      .send({ value: 0 });
    expect(res.status).toBe(200);
    expect((upsertSetting as jest.Mock).mock.calls[0][1]).toBe(0);
  });
});
