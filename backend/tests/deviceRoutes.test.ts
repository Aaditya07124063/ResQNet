import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));
jest.mock('../src/services/deviceService', () => ({
  registerDevice: jest.fn(),
  listDevices: jest.fn(),
  deleteDevice: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { deleteDevice, listDevices, registerDevice } from '../src/services/deviceService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const USER_ID = '11111111-1111-1111-1111-111111111111';
const DEVICE_ID = '22222222-2222-2222-2222-222222222222';

const user: AuthenticatedUser = {
  id: USER_ID,
  googleSubject: 'g-1',
  email: 'user@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'User',
  accountStatus: 'active',
};

function authenticateAs(u: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(u.id);
  (getUserById as jest.Mock).mockResolvedValue(u);
}

const VALID_BODY = { platform: 'android', pushProvider: 'fcm', pushToken: 'a-real-looking-fcm-token-value' };
const FAKE_DEVICE = { id: DEVICE_ID, platform: 'android', pushProvider: 'fcm', lastSeenAt: '2026-01-01T00:00:00.000Z', createdAt: '2026-01-01T00:00:00.000Z' };

describe('POST /api/v1/devices', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/devices').send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(registerDevice).not.toHaveBeenCalled();
  });

  it('rejects an invalid platform not in the schema CHECK constraint', async () => {
    authenticateAs(user);
    const res = await request(app)
      .post('/api/v1/devices')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, platform: 'smart_fridge' });
    expect(res.status).toBe(400);
    expect(registerDevice).not.toHaveBeenCalled();
  });

  it('rejects a missing pushToken', async () => {
    authenticateAs(user);
    const withoutToken: Record<string, unknown> = { ...VALID_BODY };
    delete withoutToken.pushToken;
    const res = await request(app).post('/api/v1/devices').set('Authorization', 'Bearer t').send(withoutToken);
    expect(res.status).toBe(400);
    expect(registerDevice).not.toHaveBeenCalled();
  });

  it('registers for a valid, authenticated request and never echoes the raw pushToken back', async () => {
    authenticateAs(user);
    (registerDevice as jest.Mock).mockResolvedValue(FAKE_DEVICE);
    const res = await request(app).post('/api/v1/devices').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(201);
    expect(res.body.device.id).toBe(DEVICE_ID);
    expect(res.body.device).not.toHaveProperty('pushToken');
  });

  it('derives device ownership from the session, ignoring any client-supplied identity field (cannot register under another user)', async () => {
    authenticateAs(user);
    (registerDevice as jest.Mock).mockResolvedValue(FAKE_DEVICE);
    await request(app)
      .post('/api/v1/devices')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, userId: 'attacker-controlled-id', ownerId: 'also-attacker-controlled' });
    expect((registerDevice as jest.Mock).mock.calls[0][0]).toBe(USER_ID);
    expect((registerDevice as jest.Mock).mock.calls[0][1]).not.toHaveProperty('userId');
  });

  it('handles a duplicate (same user, same token) registration safely — same 201, no error', async () => {
    authenticateAs(user);
    (registerDevice as jest.Mock).mockResolvedValue(FAKE_DEVICE); // ON CONFLICT DO UPDATE, not an error path
    const res = await request(app).post('/api/v1/devices').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(201);
  });
});

describe('GET /api/v1/devices', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/devices');
    expect(res.status).toBe(401);
  });

  it("returns the authenticated user's own devices, scoped by session identity", async () => {
    authenticateAs(user);
    (listDevices as jest.Mock).mockResolvedValue([FAKE_DEVICE, { ...FAKE_DEVICE, id: 'device-2', platform: 'ios' }]);
    const res = await request(app).get('/api/v1/devices').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200); // multiple devices for one user supported
    expect(res.body.devices).toHaveLength(2);
    expect((listDevices as jest.Mock).mock.calls[0][0]).toBe(USER_ID);
  });
});

describe('DELETE /api/v1/devices/:id', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).delete(`/api/v1/devices/${DEVICE_ID}`);
    expect(res.status).toBe(401);
    expect(deleteDevice).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID device id', async () => {
    authenticateAs(user);
    const res = await request(app).delete('/api/v1/devices/not-a-uuid').set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(deleteDevice).not.toHaveBeenCalled();
  });

  it('deletes for the owner', async () => {
    authenticateAs(user);
    const res = await request(app).delete(`/api/v1/devices/${DEVICE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(204);
    expect((deleteDevice as jest.Mock).mock.calls[0]).toEqual([USER_ID, DEVICE_ID]);
  });

  it("rejects deleting another user's device — the service's ownership-scoped query naturally 404s, proven here at the route level", async () => {
    authenticateAs(user);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (deleteDevice as jest.Mock).mockRejectedValue(HttpError.notFound('Device not found'));
    const res = await request(app).delete(`/api/v1/devices/${DEVICE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(404);
  });

  it('rate-limits repeated device registration/deletion from the same user', async () => {
    const rateLimitTestUser: AuthenticatedUser = { ...user, id: '33333333-3333-3333-3333-333333333333' };
    authenticateAs(rateLimitTestUser);
    (registerDevice as jest.Mock).mockResolvedValue(FAKE_DEVICE);
    // deviceRateLimiter defaults to 30/window.
    let lastStatus = 0;
    for (let i = 0; i < 31; i++) {
      const res = await request(app)
        .post('/api/v1/devices')
        .set('Authorization', 'Bearer t')
        .send({ ...VALID_BODY, pushToken: `token-${i}` });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});
