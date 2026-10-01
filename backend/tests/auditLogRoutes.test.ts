import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({ verifyEmployeeAccessToken: jest.fn() }));
jest.mock('../src/services/employeeService', () => ({ getEmployeeById: jest.fn() }));
jest.mock('../src/services/employeePermissionService', () => ({ hasPermission: jest.fn(), listPermissions: jest.fn() }));
jest.mock('../src/database/pool', () => ({ pool: { query: jest.fn() }, withTransaction: jest.fn() }));

import { createApp } from '../src/app';
import { pool } from '../src/database/pool';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import { redactAuditMetadata } from '../src/services/auditLogQueryService';

const app = createApp();
const employee = {
  id: '11111111-1111-1111-1111-111111111111',
  email: 'auditor@example.com',
  displayName: 'Auditor',
  role: 'admin',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};
const mockQuery = pool.query as jest.Mock;

function signedInWith(permissions: string[]) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
  (hasPermission as jest.Mock).mockImplementation(async (_e: unknown, p: string) => permissions.includes(p));
}
const get = (q = '') => request(app).get(`/api/v1/employee/audit-logs${q}`).set('Authorization', 'Bearer t');

const row = (id: string, metadata: unknown) => ({
  id,
  created_at: new Date('2026-09-28T10:00:00Z'),
  actor_user_id: null,
  actor_employee_id: employee.id,
  employee_name: 'Lead',
  employee_role: 'employee',
  action: 'incident.assigned',
  resource_type: 'sos_event',
  resource_id: '55555555-5555-5555-5555-555555555555',
  outcome: 'success',
  metadata,
});

beforeEach(() => jest.clearAllMocks());

describe('GET /api/v1/employee/audit-logs', () => {
  it('requires a session and AUDIT_LOG_VIEW', async () => {
    expect((await request(app).get('/api/v1/employee/audit-logs')).status).toBe(401);
    signedInWith(['SOS_MONITOR', 'SOS_ASSIGN']);
    expect((await get()).status).toBe(403);
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('returns entries newest first with a page marker, redacting secret-looking metadata', async () => {
    signedInWith(['AUDIT_LOG_VIEW']);
    mockQuery.mockResolvedValue({
      rows: [row('30', { previousState: 'reported', newState: 'assigned', refreshToken: 'abc' }), row('29', {}), row('28', {})],
    });
    const res = await get('?limit=2&resourceType=sos_event');
    expect(res.status).toBe(200);
    expect(res.body.entries).toHaveLength(2);
    expect(res.body.nextBefore).toBe('29');
    expect(res.body.entries[0]).toMatchObject({
      actor: { kind: 'employee', displayName: 'Lead', role: 'employee' },
      action: 'incident.assigned',
      outcome: 'success',
      metadata: { previousState: 'reported', newState: 'assigned', refreshToken: '[redacted]' },
    });
    expect(JSON.stringify(res.body)).not.toContain('abc');
    expect(res.body.entries[0]).not.toHaveProperty('ipAddress');
    const [sql, params] = mockQuery.mock.calls[0];
    expect(sql).toContain('a.resource_type = $1');
    expect(params).toEqual(['sos_event', 3]);
  });

  it.each(['?limit=0', '?limit=1000', '?before=abc', '?outcome=maybe', '?actorEmployeeId=nope'])('rejects %s', async (q) => {
    signedInWith(['AUDIT_LOG_VIEW']);
    expect((await get(q)).status).toBe(400);
  });
});

describe('redactAuditMetadata', () => {
  it('redacts nested secret-looking keys and keeps the rest', () => {
    expect(
      redactAuditMetadata({
        otp: '123456',
        nested: { apiKey: 'k', providerType: 'sparrow', list: [{ password: 'p', ok: 1 }] },
        accessToken: 't',
        sessionId: 's',
        newState: 'en_route',
      }),
    ).toEqual({
      otp: '[redacted]',
      nested: { apiKey: '[redacted]', providerType: 'sparrow', list: [{ password: '[redacted]', ok: 1 }] },
      accessToken: '[redacted]',
      sessionId: '[redacted]',
      newState: 'en_route',
    });
  });
});
