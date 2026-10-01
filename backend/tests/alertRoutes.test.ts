import request from 'supertest';

jest.mock('../src/services/employeeAuthService', () => ({ verifyEmployeeAccessToken: jest.fn() }));
jest.mock('../src/services/employeeService', () => ({ getEmployeeById: jest.fn() }));
jest.mock('../src/services/employeePermissionService', () => ({ hasPermission: jest.fn(), listPermissions: jest.fn() }));
jest.mock('../src/services/alertService', () => ({
  createAlert: jest.fn(),
  getAlert: jest.fn(),
  updateAlert: jest.fn(),
  listAllAlerts: jest.fn(),
  listActiveAlerts: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({ recordAuditEvent: jest.fn().mockResolvedValue(undefined) }));
jest.mock('../src/services/disasterSources', () => ({ getDisasterSourceStatus: jest.fn() }));

import { createApp } from '../src/app';
import { verifyEmployeeAccessToken } from '../src/services/employeeAuthService';
import { getEmployeeById } from '../src/services/employeeService';
import { hasPermission } from '../src/services/employeePermissionService';
import { createAlert, getAlert, listActiveAlerts, updateAlert } from '../src/services/alertService';
import { recordAuditEvent } from '../src/services/auditLogService';
import { getDisasterSourceStatus } from '../src/services/disasterSources';
import { listAllAlerts } from '../src/services/alertService';

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
const ALERT_ID = '44444444-4444-4444-4444-444444444444';

const officialAlert = {
  sourceType: 'official',
  sourceName: 'District Disaster Management Committee',
  category: 'flood',
  severity: 'warning',
  title: 'Flood warning',
  body: 'River levels rising.',
  latitude: 27.7,
  longitude: 85.3,
  radiusKm: 10,
};

function signedInWith(permissions: string[]) {
  (verifyEmployeeAccessToken as jest.Mock).mockReturnValue(employee.id);
  (getEmployeeById as jest.Mock).mockResolvedValue(employee);
  (hasPermission as jest.Mock).mockImplementation(async (_e: unknown, p: string) => permissions.includes(p));
}

describe('public GET /api/v1/alerts', () => {
  it('returns active alerts without requiring an account', async () => {
    (listActiveAlerts as jest.Mock).mockResolvedValue([{ id: ALERT_ID, sourceType: 'official' }]);
    const res = await request(app).get('/api/v1/alerts');
    expect(res.status).toBe(200);
    expect(res.body.alerts[0].sourceType).toBe('official');
  });
});

describe('POST /api/v1/employee/alerts', () => {
  it('requires an employee session', async () => {
    const res = await request(app).post('/api/v1/employee/alerts').send(officialAlert);
    expect(res.status).toBe(401);
  });

  it('an employee who may post ResQNet notices cannot publish an OFFICIAL alert — and the attempt is audited', async () => {
    signedInWith(['SYSTEM_ALERT_PUBLISH']);
    const res = await request(app).post('/api/v1/employee/alerts').set('Authorization', 'Bearer t').send(officialAlert);
    expect(res.status).toBe(403);
    expect(createAlert).not.toHaveBeenCalled();
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'emergency_alert.create', outcome: 'denied' }),
    );
  });

  it('OFFICIAL_ALERT_PUBLISH can publish an official alert', async () => {
    signedInWith(['OFFICIAL_ALERT_PUBLISH']);
    (createAlert as jest.Mock).mockResolvedValue({ id: ALERT_ID, ...officialAlert });
    const res = await request(app).post('/api/v1/employee/alerts').set('Authorization', 'Bearer t').send(officialAlert);
    expect(res.status).toBe(201);
    expect(createAlert).toHaveBeenCalledWith(employee.id, expect.objectContaining({ sourceType: 'official' }));
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'emergency_alert.create', outcome: 'success', resourceId: ALERT_ID }),
    );
  });

  it.each([
    ['staff cannot issue community reports', { ...officialAlert, sourceType: 'community' }],
    ['a partial circle', { ...officialAlert, radiusKm: undefined }],
    ['no geographic scope', { ...officialAlert, latitude: undefined, longitude: undefined, radiusKm: undefined }],
    ['an unknown severity', { ...officialAlert, severity: 'apocalyptic' }],
  ])('rejects %s', async (_name, body) => {
    signedInWith(['OFFICIAL_ALERT_PUBLISH']);
    const res = await request(app).post('/api/v1/employee/alerts').set('Authorization', 'Bearer t').send(body);
    expect(res.status).toBe(400);
  });

  it('accepts an administrative-area scope without a circle', async () => {
    signedInWith(['OFFICIAL_ALERT_PUBLISH']);
    (createAlert as jest.Mock).mockResolvedValue({ id: ALERT_ID });
    const areaOnly = { ...officialAlert, latitude: undefined, longitude: undefined, radiusKm: undefined };
    const res = await request(app)
      .post('/api/v1/employee/alerts')
      .set('Authorization', 'Bearer t')
      .send({ ...areaOnly, province: 'Bagmati', district: 'Kathmandu' });
    expect(res.status).toBe(201);
  });
});

describe('PATCH /api/v1/employee/alerts/:id', () => {
  it('editing an official alert needs the official permission, whoever created it', async () => {
    signedInWith(['PARTNER_ALERT_PUBLISH']);
    (getAlert as jest.Mock).mockResolvedValue({ id: ALERT_ID, sourceType: 'official' });
    const res = await request(app)
      .patch(`/api/v1/employee/alerts/${ALERT_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'resolved' });
    expect(res.status).toBe(403);
    expect(updateAlert).not.toHaveBeenCalled();
  });

  it('resolves an alert and audits the change', async () => {
    signedInWith(['OFFICIAL_ALERT_PUBLISH']);
    (getAlert as jest.Mock).mockResolvedValue({ id: ALERT_ID, sourceType: 'official' });
    (updateAlert as jest.Mock).mockResolvedValue({ id: ALERT_ID, status: 'resolved' });
    const res = await request(app)
      .patch(`/api/v1/employee/alerts/${ALERT_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'resolved' });
    expect(res.status).toBe(200);
    expect(recordAuditEvent).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'emergency_alert.update', metadata: { changed: ['status'], status: 'resolved' } }),
    );
  });
});

describe('reading alerts and sources as staff', () => {
  const auth = (r: request.Test) => r.set('Authorization', 'Bearer t');

  it('SOS_MONITOR can read alerts and source status but cannot publish', async () => {
    signedInWith(['SOS_MONITOR']);
    (listAllAlerts as jest.Mock).mockResolvedValue([]);
    (getDisasterSourceStatus as jest.Mock).mockResolvedValue({ registered: [], scheduledIngestion: false, observed: [] });
    expect((await auth(request(app).get('/api/v1/employee/alerts'))).status).toBe(200);
    const sources = await auth(request(app).get('/api/v1/employee/alerts/sources'));
    expect(sources.status).toBe(200);
    expect(sources.body.sources).toEqual({ registered: [], scheduledIngestion: false, observed: [] });
    expect((await auth(request(app).post('/api/v1/employee/alerts')).send(officialAlert)).status).toBe(403);
  });

  it('an employee with no alert or monitoring permission cannot read either', async () => {
    signedInWith(['SMS_PROVIDER_MANAGE']);
    expect((await auth(request(app).get('/api/v1/employee/alerts'))).status).toBe(403);
    expect((await auth(request(app).get('/api/v1/employee/alerts/sources'))).status).toBe(403);
  });
});
