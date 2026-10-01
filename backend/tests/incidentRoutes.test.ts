import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({ verifyEmployeeAccessToken: jest.fn() }));
jest.mock('../src/services/employeeService', () => ({ getEmployeeById: jest.fn() }));
jest.mock('../src/services/employeePermissionService', () => ({ hasPermission: jest.fn(), listPermissions: jest.fn() }));
jest.mock('../src/services/incidentService', () => ({
  QUEUE_PAGE_MAX: 200,
  listIncidents: jest.fn(),
  getIncident: jest.fn(),
  recordIncidentUpdate: jest.fn(),
  getIncidentCounts: jest.fn(),
  listEligibleResponders: jest.fn(),
  setRetentionHold: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({ recordAuditEvent: jest.fn().mockResolvedValue(undefined) }));

import { createApp } from '../src/app';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import {
  getIncident,
  getIncidentCounts,
  listEligibleResponders,
  listIncidents,
  recordIncidentUpdate,
  setRetentionHold,
} from '../src/services/incidentService';
import { HttpError } from '../src/utils/httpError';
import { recordAuditEvent } from '../src/services/auditLogService';

const app = createApp();
const employee = {
  id: '11111111-1111-1111-1111-111111111111',
  email: 'ops@example.com',
  displayName: 'Ops',
  role: 'employee',
  status: 'active',
  createdAt: '2026-01-01T00:00:00.000Z',
  lastLoginAt: null,
};
const INCIDENT = '55555555-5555-5555-5555-555555555555';
const OTHER = '66666666-6666-6666-6666-666666666666';

function signedInWith(permissions: string[]) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
  (hasPermission as jest.Mock).mockImplementation(async (_e: unknown, p: string) => permissions.includes(p));
}

beforeEach(() => jest.clearAllMocks());

const auth = (r: request.Test) => r.set('Authorization', 'Bearer t');
const update = (body: object) => auth(request(app).post(`/api/v1/employee/incidents/${INCIDENT}/updates`)).send(body);

describe('incident queue', () => {
  it('requires an employee session', async () => {
    expect((await request(app).get('/api/v1/employee/incidents')).status).toBe(401);
  });

  it('requires SOS_MONITOR', async () => {
    signedInWith(['SOS_RESPOND', 'SOS_ASSIGN']);
    const res = await auth(request(app).get('/api/v1/employee/incidents'));
    expect(res.status).toBe(403);
    expect(listIncidents).not.toHaveBeenCalled();
  });

  it('lists active incidents by default, with a cursor for the next page', async () => {
    signedInWith(['SOS_MONITOR']);
    (listIncidents as jest.Mock).mockResolvedValue({ incidents: [{ id: INCIDENT, opsStatus: 'reported' }], nextCursor: 'c1' });
    const res = await auth(request(app).get('/api/v1/employee/incidents'));
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ incidents: [{ id: INCIDENT, opsStatus: 'reported' }], nextCursor: 'c1' });
    expect(listIncidents).toHaveBeenCalledWith({ scope: 'active', limit: undefined, cursor: undefined });
  });

  it('passes scope, limit and cursor through; include=closed still means all', async () => {
    signedInWith(['SOS_MONITOR']);
    (listIncidents as jest.Mock).mockResolvedValue({ incidents: [], nextCursor: null });
    await auth(request(app).get('/api/v1/employee/incidents?scope=closed&limit=50&cursor=abc'));
    expect(listIncidents).toHaveBeenLastCalledWith({ scope: 'closed', limit: 50, cursor: 'abc' });
    await auth(request(app).get('/api/v1/employee/incidents?include=closed'));
    expect(listIncidents).toHaveBeenLastCalledWith({ scope: 'all', limit: undefined, cursor: undefined });
  });

  it('rejects an out-of-range page size', async () => {
    signedInWith(['SOS_MONITOR']);
    expect((await auth(request(app).get('/api/v1/employee/incidents?limit=5000'))).status).toBe(400);
    expect((await auth(request(app).get('/api/v1/employee/incidents?scope=everything'))).status).toBe(400);
    expect(listIncidents).not.toHaveBeenCalled();
  });
});

describe('incident detail', () => {
  it('SOS_MONITOR alone gets no exact location or phone — and the view is audited', async () => {
    signedInWith(['SOS_MONITOR']);
    (getIncident as jest.Mock).mockResolvedValue({ id: INCIDENT, timeline: [] });
    const res = await auth(request(app).get(`/api/v1/employee/incidents/${INCIDENT}`));
    expect(res.status).toBe(200);
    expect(getIncident).toHaveBeenCalledWith(INCIDENT, { includeSensitive: false });
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'incident.view',
        resourceId: INCIDENT,
        outcome: 'success',
        metadata: { actorRole: 'employee', sensitiveDetailsIncluded: false },
      }),
    );
  });

  it('SOS_MONITOR + SOS_RESPOND includes contact details', async () => {
    signedInWith(['SOS_MONITOR', 'SOS_RESPOND']);
    (getIncident as jest.Mock).mockResolvedValue({ id: INCIDENT, timeline: [] });
    await auth(request(app).get(`/api/v1/employee/incidents/${INCIDENT}`));
    expect(getIncident).toHaveBeenCalledWith(INCIDENT, { includeSensitive: true });
  });

  it('SOS_RESPOND without SOS_MONITOR cannot open an incident', async () => {
    signedInWith(['SOS_RESPOND']);
    expect((await auth(request(app).get(`/api/v1/employee/incidents/${INCIDENT}`))).status).toBe(403);
    expect(getIncident).not.toHaveBeenCalled();
  });

  it('a malformed id is a 404, not a database error', async () => {
    signedInWith(['SOS_MONITOR']);
    expect((await auth(request(app).get('/api/v1/employee/incidents/not-a-uuid'))).status).toBe(404);
    expect(getIncident).not.toHaveBeenCalled();
  });
});

describe('responder updates', () => {
  it('monitoring alone cannot change an incident', async () => {
    signedInWith(['SOS_MONITOR']);
    expect((await update({ action: 'acknowledged' })).status).toBe(403);
    expect(recordIncidentUpdate).not.toHaveBeenCalled();
  });

  it('SOS_RESPOND records progress; the audit has actor role and both states but not the note text', async () => {
    signedInWith(['SOS_RESPOND']);
    (recordIncidentUpdate as jest.Mock).mockResolvedValue({
      previousState: 'assigned',
      newState: 'en_route',
      civilianState: 'active',
    });
    const res = await update({ action: 'en_route', note: 'Leg injury, bleeding' });
    expect(res.status).toBe(201);
    expect(res.body).toEqual({ opsStatus: 'en_route', previousState: 'assigned' });
    expect(recordIncidentUpdate).toHaveBeenCalledWith(
      { id: employee.id, role: 'employee', canAssign: false },
      INCIDENT,
      { action: 'en_route', note: 'Leg injury, bleeding' },
    );
    const audit = (recordAuditEvent as jest.Mock).mock.calls[0][0];
    expect(audit).toMatchObject({
      actorEmployeeId: employee.id,
      action: 'incident.en_route',
      outcome: 'success',
      metadata: { actorRole: 'employee', previousState: 'assigned', newState: 'en_route', hasNote: true },
    });
    expect(JSON.stringify(audit)).not.toContain('Leg injury');
  });

  it('passes canAssign only when the employee holds SOS_ASSIGN', async () => {
    signedInWith(['SOS_RESPOND', 'SOS_ASSIGN']);
    (recordIncidentUpdate as jest.Mock).mockResolvedValue({ previousState: 'reported', newState: 'assigned', civilianState: 'active' });
    await update({ action: 'assigned', assignedEmployeeId: OTHER });
    expect((recordIncidentUpdate as jest.Mock).mock.calls[0][0]).toMatchObject({ canAssign: true });
  });

  it('a refusal from the service is returned and audited as denied', async () => {
    signedInWith(['SOS_RESPOND']);
    (recordIncidentUpdate as jest.Mock).mockRejectedValue(HttpError.forbidden('Missing required permission: SOS_ASSIGN'));
    const res = await update({ action: 'assigned', assignedEmployeeId: OTHER });
    expect(res.status).toBe(403);
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'incident.assigned', outcome: 'denied', metadata: expect.objectContaining({ reason: 'FORBIDDEN' }) }),
    );
  });

  it('an invalid transition is a 409 INVALID_TRANSITION and is audited', async () => {
    signedInWith(['SOS_RESPOND']);
    (recordIncidentUpdate as jest.Mock).mockRejectedValue(
      new HttpError(409, 'INVALID_TRANSITION', 'Cannot go from arrived to acknowledged; allowed next: assisting, resolved'),
    );
    const res = await update({ action: 'acknowledged' });
    expect(res.status).toBe(409);
    expect(res.body.error).toEqual({
      code: 'INVALID_TRANSITION',
      message: 'Cannot go from arrived to acknowledged; allowed next: assisting, resolved',
    });
    expect(recordAuditEvent).toHaveBeenCalledWith(expect.objectContaining({ outcome: 'denied' }));
  });

  it('rejects unknown actions (including the internal civilian_state) before touching the service', async () => {
    signedInWith(['SOS_RESPOND', 'SOS_ASSIGN']);
    for (const action of ['reported', 'civilian_state', 'reopen']) {
      expect((await update({ action })).status).toBe(400);
    }
    expect(recordIncidentUpdate).not.toHaveBeenCalled();
  });
});

describe('queue filters, dashboard counts and the responder list', () => {
  it('passes validated filters to the queue', async () => {
    signedInWith(['SOS_MONITOR']);
    (listIncidents as jest.Mock).mockResolvedValue({ incidents: [], nextCursor: null });
    await auth(request(app).get(`/api/v1/employee/incidents?opsStatus=en_route&civilianState=safe&assignee=${OTHER}`));
    expect(listIncidents).toHaveBeenLastCalledWith({
      scope: 'active',
      limit: undefined,
      cursor: undefined,
      opsStatus: 'en_route',
      civilianState: 'safe',
      assignee: OTHER,
    });
    await auth(request(app).get('/api/v1/employee/incidents?assignee=unassigned'));
    expect((listIncidents as jest.Mock).mock.calls.at(-1)[0]).toMatchObject({ assignee: 'unassigned' });
  });

  it.each(['opsStatus=flying', 'civilianState=happy', 'assignee=bob'])('rejects %s', async (q) => {
    signedInWith(['SOS_MONITOR']);
    expect((await auth(request(app).get(`/api/v1/employee/incidents?${q}`))).status).toBe(400);
  });

  it('dashboard counts need SOS_MONITOR', async () => {
    signedInWith(['SOS_RESPOND']);
    expect((await auth(request(app).get('/api/v1/employee/incidents/summary'))).status).toBe(403);
    signedInWith(['SOS_MONITOR']);
    (getIncidentCounts as jest.Mock).mockResolvedValue({ generatedAt: 't', byResponderState: {} });
    const res = await auth(request(app).get('/api/v1/employee/incidents/summary'));
    expect(res.status).toBe(200);
    expect(res.body.counts.generatedAt).toBe('t');
    expect(getIncident).not.toHaveBeenCalled(); // not treated as an incident id
  });

  it('the responder list needs SOS_ASSIGN', async () => {
    signedInWith(['SOS_MONITOR', 'SOS_RESPOND']);
    expect((await auth(request(app).get('/api/v1/employee/incidents/responders'))).status).toBe(403);
    signedInWith(['SOS_ASSIGN']);
    (listEligibleResponders as jest.Mock).mockResolvedValue([{ id: OTHER, displayName: 'Medic', role: 'employee', openAssignments: 0 }]);
    const res = await auth(request(app).get('/api/v1/employee/incidents/responders'));
    expect(res.status).toBe(200);
    expect(res.body.responders[0]).not.toHaveProperty('email');
  });
});

describe('retention hold', () => {
  const hold = (body: object) => auth(request(app).post(`/api/v1/employee/incidents/${INCIDENT}/retention-hold`)).send(body);

  it('needs RETENTION_HOLD_MANAGE', async () => {
    signedInWith(['SOS_MONITOR', 'SOS_RESPOND', 'SOS_ASSIGN']);
    expect((await hold({ hold: true, reason: 'Investigation' })).status).toBe(403);
    expect(setRetentionHold).not.toHaveBeenCalled();
  });

  it('needs a reason to place a hold', async () => {
    signedInWith(['RETENTION_HOLD_MANAGE']);
    expect((await hold({ hold: true })).status).toBe(400);
    expect((await hold({ hold: true, reason: ' ' })).status).toBe(400);
  });

  it('places a hold and audits it without the reason text', async () => {
    signedInWith(['RETENTION_HOLD_MANAGE']);
    (setRetentionHold as jest.Mock).mockResolvedValue({ held: true, sensitiveAlreadyRedacted: false });
    const res = await hold({ hold: true, reason: 'Police request 2026/114' });
    expect(res.status).toBe(200);
    expect(setRetentionHold).toHaveBeenCalledWith(employee.id, INCIDENT, { hold: true, reason: 'Police request 2026/114' });
    const audit = (recordAuditEvent as jest.Mock).mock.calls.at(-1)[0];
    expect(audit).toMatchObject({ action: 'incident.retention_hold', outcome: 'success' });
    expect(JSON.stringify(audit)).not.toContain('Police request');
  });
});
