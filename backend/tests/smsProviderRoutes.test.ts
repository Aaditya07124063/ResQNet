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
jest.mock('../src/services/smsProviderAdminService', () => ({
  listSmsProviders: jest.fn(),
  createSmsProvider: jest.fn(),
  updateSmsProvider: jest.fn(),
  disableSmsProvider: jest.fn(),
  testSmsProvider: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({
  recordAuditEvent: jest.fn().mockResolvedValue(undefined),
}));

import { createApp } from '../src/app';
import { HttpError } from '../src/utils/httpError';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import {
  createSmsProvider,
  disableSmsProvider,
  listSmsProviders,
  testSmsProvider,
  updateSmsProvider,
} from '../src/services/smsProviderAdminService';
import { recordAuditEvent } from '../src/services/auditLogService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const app = createApp();
const PROVIDER_ID = '22222222-2222-2222-2222-222222222222';
const BASE = '/api/v1/employee/sms-providers';

const employee: AuthenticatedEmployee = {
  id: '11111111-1111-1111-1111-111111111111',
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

const provider = {
  id: PROVIDER_ID,
  providerType: 'sparrow_sms',
  displayName: 'Sparrow',
  enabled: true,
  priority: 10,
  configuredCredentialFields: ['token'],
};

describe('SMS provider routes — authentication and authorization', () => {
  const calls: Array<[string, () => request.Test]> = [
    ['GET list', () => request(app).get(BASE)],
    ['POST create', () => request(app).post(BASE).send({})],
    ['PATCH update', () => request(app).patch(`${BASE}/${PROVIDER_ID}`).send({ enabled: false })],
    ['DELETE disable', () => request(app).delete(`${BASE}/${PROVIDER_ID}`)],
    ['POST test', () => request(app).post(`${BASE}/${PROVIDER_ID}/test`).send({ phoneNumber: '9812345678' })],
  ];

  it.each(calls)('%s rejects an unauthenticated request with 401', async (_name, call) => {
    const res = await call();
    expect(res.status).toBe(401);
  });

  it.each(calls)('%s rejects an invalid or expired employee token with 401', async (_name, call) => {
    (verifyEmployeeAccessToken as jest.Mock).mockImplementation(() => {
      throw HttpError.unauthorized('Invalid or expired access token');
    });
    const res = await call().set('Authorization', 'Bearer expired');
    expect(res.status).toBe(401);
  });

  it.each(calls)('%s rejects an employee without SMS_PROVIDER_MANAGE with 403', async (_name, call) => {
    authenticateAs(false);
    const res = await call().set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(hasPermission).toHaveBeenCalledWith(expect.objectContaining({ id: employee.id }), 'SMS_PROVIDER_MANAGE');
    expect(listSmsProviders).not.toHaveBeenCalled();
    expect(createSmsProvider).not.toHaveBeenCalled();
    expect(updateSmsProvider).not.toHaveBeenCalled();
    expect(disableSmsProvider).not.toHaveBeenCalled();
    expect(testSmsProvider).not.toHaveBeenCalled();
  });
});

describe('SMS provider routes — permitted employee', () => {
  beforeEach(() => {
    (verifyEmployeeAccessToken as jest.Mock).mockReset();
    authenticateAs(true);
  });

  it('lists the catalog and configured providers', async () => {
    (listSmsProviders as jest.Mock).mockResolvedValue({ catalog: [], providers: [provider] });
    const res = await request(app).get(BASE).set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.providers).toHaveLength(1);
  });

  it('creates a provider and audits it without credential values', async () => {
    (createSmsProvider as jest.Mock).mockResolvedValue(provider);
    const res = await request(app)
      .post(BASE)
      .set('Authorization', 'Bearer t')
      .send({ providerType: 'sparrow_sms', displayName: 'Sparrow', credentials: { token: 'secret-token' }, configuration: { from: 'ResQNet' } });
    expect(res.status).toBe(201);
    expect(JSON.stringify(res.body)).not.toContain('secret-token');
    expect(JSON.stringify((recordAuditEvent as jest.Mock).mock.calls)).not.toContain('secret-token');
  });

  it('rejects nested objects in credentials', async () => {
    const res = await request(app)
      .post(BASE)
      .set('Authorization', 'Bearer t')
      .send({ providerType: 'sparrow_sms', displayName: 'S', credentials: { token: { $ne: 1 } }, configuration: {} });
    expect(res.status).toBe(400);
    expect(createSmsProvider).not.toHaveBeenCalled();
  });

  it('rejects an empty update', async () => {
    const res = await request(app).patch(`${BASE}/${PROVIDER_ID}`).set('Authorization', 'Bearer t').send({});
    expect(res.status).toBe(400);
  });

  it('returns 404 for a malformed provider id instead of querying with it', async () => {
    const res = await request(app).patch(`${BASE}/not-a-uuid`).set('Authorization', 'Bearer t').send({ enabled: false });
    expect(res.status).toBe(404);
    expect(updateSmsProvider).not.toHaveBeenCalled();
  });

  it('records which credential fields changed, never their values', async () => {
    (updateSmsProvider as jest.Mock).mockResolvedValue(provider);
    const res = await request(app)
      .patch(`${BASE}/${PROVIDER_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ credentials: { token: 'rotated-secret' } });
    expect(res.status).toBe(200);
    const audit = (recordAuditEvent as jest.Mock).mock.calls.at(-1)[0];
    expect(audit.metadata.credentialFields).toEqual(['token']);
    expect(JSON.stringify(audit)).not.toContain('rotated-secret');
  });

  it('soft-disables on DELETE', async () => {
    (disableSmsProvider as jest.Mock).mockResolvedValue(undefined);
    const res = await request(app).delete(`${BASE}/${PROVIDER_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(204);
    expect(disableSmsProvider).toHaveBeenCalledWith(PROVIDER_ID);
  });

  it('normalizes the test phone number and returns the classified result', async () => {
    (testSmsProvider as jest.Mock).mockResolvedValue({ status: 'failed', failure: 'configuration', message: 'm' });
    const res = await request(app)
      .post(`${BASE}/${PROVIDER_ID}/test`)
      .set('Authorization', 'Bearer t')
      .send({ phoneNumber: '9812345678' });
    expect(res.status).toBe(200);
    expect(res.body.result).toEqual({ status: 'failed', failure: 'configuration', message: 'm' });
    expect(testSmsProvider).toHaveBeenCalledWith(PROVIDER_ID, '+9779812345678');
  });

  it('rejects an invalid test phone number', async () => {
    const res = await request(app)
      .post(`${BASE}/${PROVIDER_ID}/test`)
      .set('Authorization', 'Bearer t')
      .send({ phoneNumber: 'abcdefg' });
    expect(res.status).toBe(400);
    expect(testSmsProvider).not.toHaveBeenCalled();
  });
});
