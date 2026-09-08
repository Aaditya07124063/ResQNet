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
jest.mock('../src/services/moderationService', () => ({
  listReviewCases: jest.fn(),
  getReviewCaseWithReports: jest.fn(),
  takeModerationAction: jest.fn(),
}));
// Verifies requireAuth (the CONSUMER user middleware) never accidentally
// guards these routes — a normal user's session must be irrelevant here.
jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import { getReviewCaseWithReports, listReviewCases, takeModerationAction } from '../src/services/moderationService';
import type { AuthenticatedEmployee } from '../src/models/Employee';

const app = createApp();

const EMPLOYEE_ID = '11111111-1111-1111-1111-111111111111';
const CASE_ID = '22222222-2222-2222-2222-222222222222';

const employee: AuthenticatedEmployee = {
  id: EMPLOYEE_ID,
  email: 'mod@example.com',
  displayName: 'Moderator',
  role: 'employee',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};

function authenticateAs(emp: AuthenticatedEmployee, permitted: boolean) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(emp.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(emp);
  (hasPermission as jest.Mock).mockResolvedValue(permitted);
}

const FAKE_CASE = {
  id: CASE_ID,
  targetUserId: 'target-1',
  status: 'open',
  triggerReason: 'report_threshold',
  reportCountAtOpen: 3,
  openedAt: '2026-01-01T00:00:00.000Z',
  closedAt: null,
  closedByEmployeeId: null,
};

describe('GET /api/v1/employee/review-cases', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/employee/review-cases');
    expect(res.status).toBe(401);
    expect(listReviewCases).not.toHaveBeenCalled();
  });

  it('denies a normal consumer user session (not an employee session at all)', async () => {
    // No employee mocks configured to succeed — verifyEmployeeAccessToken
    // throwing is exactly what happens for a token signed with the
    // consumer JWT_ACCESS_SECRET instead of EMPLOYEE_JWT_ACCESS_SECRET
    // (see employeeAuthService.test.ts for the real cross-verification
    // proof); this route-level test confirms the route is actually wired
    // to requireEmployeeAuth, not requireAuth.
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (verifyEmployeeAccessToken as jest.Mock).mockImplementation(() => {
      throw HttpError.unauthorized('Invalid or expired employee session token');
    });
    const res = await request(app).get('/api/v1/employee/review-cases').set('Authorization', 'Bearer consumer-user-token');
    expect(res.status).toBe(401);
    expect(listReviewCases).not.toHaveBeenCalled();
  });

  it('denies an employee without USER_VIEW', async () => {
    authenticateAs(employee, false);
    const res = await request(app).get('/api/v1/employee/review-cases').set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(listReviewCases).not.toHaveBeenCalled();
  });

  it('allows a permitted employee, defaulting to no filter', async () => {
    authenticateAs(employee, true);
    (listReviewCases as jest.Mock).mockResolvedValue([FAKE_CASE]);
    const res = await request(app).get('/api/v1/employee/review-cases').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.reviewCases).toHaveLength(1);
    expect((listReviewCases as jest.Mock).mock.calls[0][0]).toBeUndefined();
  });

  it('passes a valid status filter through', async () => {
    authenticateAs(employee, true);
    (listReviewCases as jest.Mock).mockResolvedValue([]);
    await request(app).get('/api/v1/employee/review-cases?status=closed').set('Authorization', 'Bearer t');
    expect((listReviewCases as jest.Mock).mock.calls[0][0]).toBe('closed');
  });

  it('rejects an invalid status filter', async () => {
    authenticateAs(employee, true);
    const res = await request(app).get('/api/v1/employee/review-cases?status=bogus').set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(listReviewCases).not.toHaveBeenCalled();
  });

  it('super_admin sees cases without an explicit permission grant (RBAC bypass, per Phase 15)', async () => {
    authenticateAs({ ...employee, role: 'super_admin' }, true);
    (listReviewCases as jest.Mock).mockResolvedValue([]);
    const res = await request(app).get('/api/v1/employee/review-cases').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
  });
});

describe('GET /api/v1/employee/review-cases/:id', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get(`/api/v1/employee/review-cases/${CASE_ID}`);
    expect(res.status).toBe(401);
  });

  it('denies without USER_VIEW', async () => {
    authenticateAs(employee, false);
    const res = await request(app).get(`/api/v1/employee/review-cases/${CASE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(403);
    expect(getReviewCaseWithReports).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID id (invalid review-case id)', async () => {
    authenticateAs(employee, true);
    const res = await request(app).get('/api/v1/employee/review-cases/not-a-uuid').set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(getReviewCaseWithReports).not.toHaveBeenCalled();
  });

  it('404s for a well-formed but nonexistent id', async () => {
    authenticateAs(employee, true);
    (getReviewCaseWithReports as jest.Mock).mockResolvedValue(null);
    const res = await request(app).get(`/api/v1/employee/review-cases/${CASE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(404);
  });

  it('returns the case and its reports, including reporter identity (employee-only view)', async () => {
    authenticateAs(employee, true);
    (getReviewCaseWithReports as jest.Mock).mockResolvedValue({
      reviewCase: FAKE_CASE,
      reports: [{ id: 'r1', reporterUserId: 'reporter-1', reportedUserId: 'target-1', reason: 'x', description: null, status: 'open', resolution: null, resolvedByEmployeeId: null, resolvedAt: null, createdAt: '2026-01-01T00:00:00.000Z' }],
    });
    const res = await request(app).get(`/api/v1/employee/review-cases/${CASE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.reports[0].reporterUserId).toBe('reporter-1');
  });
});

describe('POST /api/v1/employee/review-cases/:id/actions', () => {
  const VALID_BODY = { actionType: 'dismiss', reason: 'no violation found' };

  it('denies an unauthenticated request', async () => {
    const res = await request(app).post(`/api/v1/employee/review-cases/${CASE_ID}/actions`).send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(takeModerationAction).not.toHaveBeenCalled();
  });

  it('denies an employee with USER_VIEW but not USER_SUSPEND', async () => {
    authenticateAs(employee, false);
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send(VALID_BODY);
    expect(res.status).toBe(403);
    expect(takeModerationAction).not.toHaveBeenCalled();
  });

  it('rejects an invalid actionType not in the schema CHECK constraint', async () => {
    authenticateAs(employee, true);
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send({ actionType: 'ban_forever' });
    expect(res.status).toBe(400);
    expect(takeModerationAction).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID review-case id', async () => {
    authenticateAs(employee, true);
    const res = await request(app)
      .post('/api/v1/employee/review-cases/not-a-uuid/actions')
      .set('Authorization', 'Bearer t')
      .send(VALID_BODY);
    expect(res.status).toBe(400);
    expect(takeModerationAction).not.toHaveBeenCalled();
  });

  it('derives the acting employee identity from the session, ignoring any client-supplied identity field', async () => {
    authenticateAs(employee, true);
    (takeModerationAction as jest.Mock).mockResolvedValue({
      action: { id: 'a1', targetUserId: 'target-1', reviewCaseId: CASE_ID, actionType: 'dismiss', performedByEmployeeId: EMPLOYEE_ID, reason: null, createdAt: '2026-01-01T00:00:00.000Z' },
      reviewCase: { ...FAKE_CASE, status: 'closed' },
    });

    await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, performedByEmployeeId: 'attacker-controlled-id', employeeId: 'also-attacker-controlled' });

    expect((takeModerationAction as jest.Mock).mock.calls[0][1]).toBe(EMPLOYEE_ID);
    expect((takeModerationAction as jest.Mock).mock.calls[0][2]).not.toHaveProperty('performedByEmployeeId');
  });

  it('propagates a not-found review case as 404', async () => {
    authenticateAs(employee, true);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (takeModerationAction as jest.Mock).mockRejectedValue(HttpError.notFound('Review case not found'));
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send(VALID_BODY);
    expect(res.status).toBe(404);
  });

  it('propagates an already-closed (duplicate action / invalid state transition) case as 409', async () => {
    authenticateAs(employee, true);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (takeModerationAction as jest.Mock).mockRejectedValue(HttpError.conflict('This review case is already closed'));
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send(VALID_BODY);
    expect(res.status).toBe(409);
  });

  it('succeeds for a valid, authorized request', async () => {
    authenticateAs(employee, true);
    (takeModerationAction as jest.Mock).mockResolvedValue({
      action: { id: 'a1', targetUserId: 'target-1', reviewCaseId: CASE_ID, actionType: 'dismiss', performedByEmployeeId: EMPLOYEE_ID, reason: 'no violation found', createdAt: '2026-01-01T00:00:00.000Z' },
      reviewCase: { ...FAKE_CASE, status: 'closed', closedByEmployeeId: EMPLOYEE_ID },
    });
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send(VALID_BODY);
    expect(res.status).toBe(201);
    expect(res.body.reviewCase.status).toBe('closed');
  });

  it('a SQL-injection-shaped reason string reaches the service intact rather than being rejected or mangled', async () => {
    authenticateAs(employee, true);
    const injection = "'; DROP TABLE users; --";
    (takeModerationAction as jest.Mock).mockResolvedValue({
      action: { id: 'a1', targetUserId: 'target-1', reviewCaseId: CASE_ID, actionType: 'dismiss', performedByEmployeeId: EMPLOYEE_ID, reason: injection, createdAt: '2026-01-01T00:00:00.000Z' },
      reviewCase: { ...FAKE_CASE, status: 'closed' },
    });
    const res = await request(app)
      .post(`/api/v1/employee/review-cases/${CASE_ID}/actions`)
      .set('Authorization', 'Bearer t')
      .send({ actionType: 'dismiss', reason: injection });
    expect(res.status).toBe(201);
    expect((takeModerationAction as jest.Mock).mock.calls[0][2].reason).toBe(injection);
  });
});
