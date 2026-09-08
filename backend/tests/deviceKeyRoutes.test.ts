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
jest.mock('../src/services/deviceKeyService', () => ({
  registerDeviceKey: jest.fn(),
  listDeviceKeys: jest.fn(),
  revokeDeviceKey: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { registerDeviceKey, listDeviceKeys, revokeDeviceKey } from '../src/services/deviceKeyService';
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

// A real (well-formed, but not the point of this test — that's
// originSignature.test.ts's job) SPKI PEM shape is not required here
// since the service layer is mocked; only routing/validation is exercised.
const VALID_BODY = {
  deviceId: DEVICE_ID,
  keyId: 'a'.repeat(44),
  publicKey: '-----BEGIN PUBLIC KEY-----\nMFkw...fake...\n-----END PUBLIC KEY-----',
  algorithm: 'ECDSA_P256_SHA256',
};
const FAKE_DEVICE_KEY = {
  id: 'dk-1',
  deviceId: DEVICE_ID,
  keyId: VALID_BODY.keyId,
  algorithm: 'ECDSA_P256_SHA256',
  registeredAt: '2026-01-01T00:00:00.000Z',
  revokedAt: null,
};

beforeEach(() => jest.clearAllMocks());

describe('POST /api/v1/devices/keys', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/devices/keys').send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(registerDeviceKey).not.toHaveBeenCalled();
  });

  it('rejects an unsupported algorithm', async () => {
    authenticateAs(user);
    const res = await request(app)
      .post('/api/v1/devices/keys')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, algorithm: 'RSA_2048' });
    expect(res.status).toBe(400);
    expect(registerDeviceKey).not.toHaveBeenCalled();
  });

  it('rejects a missing publicKey', async () => {
    authenticateAs(user);
    const withoutKey: Record<string, unknown> = { ...VALID_BODY };
    delete withoutKey.publicKey;
    const res = await request(app).post('/api/v1/devices/keys').set('Authorization', 'Bearer t').send(withoutKey);
    expect(res.status).toBe(400);
    expect(registerDeviceKey).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID deviceId', async () => {
    authenticateAs(user);
    const res = await request(app)
      .post('/api/v1/devices/keys')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, deviceId: 'not-a-uuid' });
    expect(res.status).toBe(400);
    expect(registerDeviceKey).not.toHaveBeenCalled();
  });

  it('registers for a valid, authenticated request and reports how many pending events were reconciled', async () => {
    authenticateAs(user);
    (registerDeviceKey as jest.Mock).mockResolvedValue({ deviceKey: FAKE_DEVICE_KEY, reconciledEventCount: 2 });
    const res = await request(app).post('/api/v1/devices/keys').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(201);
    expect(res.body.deviceKey.deviceId).toBe(DEVICE_ID);
    expect(res.body.deviceKey).not.toHaveProperty('publicKey');
    expect(res.body.reconciledEventCount).toBe(2);
  });

  it('derives ownership from the session, ignoring any client-supplied identity field', async () => {
    authenticateAs(user);
    (registerDeviceKey as jest.Mock).mockResolvedValue({ deviceKey: FAKE_DEVICE_KEY, reconciledEventCount: 0 });
    await request(app)
      .post('/api/v1/devices/keys')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, userId: 'attacker-controlled-id' });
    expect((registerDeviceKey as jest.Mock).mock.calls[0][0]).toBe(USER_ID);
    expect((registerDeviceKey as jest.Mock).mock.calls[0][1]).not.toHaveProperty('userId');
  });

  it('surfaces a 409 when the service reports the (deviceId, keyId) pair belongs to a different account', async () => {
    authenticateAs(user);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (registerDeviceKey as jest.Mock).mockRejectedValue(
      HttpError.conflict('This device key is already registered to a different account'),
    );
    const res = await request(app).post('/api/v1/devices/keys').set('Authorization', 'Bearer t').send(VALID_BODY);
    expect(res.status).toBe(409);
  });
});

describe('GET /api/v1/devices/keys', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/devices/keys');
    expect(res.status).toBe(401);
  });

  it("returns the authenticated user's own device keys, never the raw public key material", async () => {
    authenticateAs(user);
    (listDeviceKeys as jest.Mock).mockResolvedValue([FAKE_DEVICE_KEY]);
    const res = await request(app).get('/api/v1/devices/keys').set('Authorization', 'Bearer t');
    expect(res.status).toBe(200);
    expect(res.body.deviceKeys).toHaveLength(1);
    expect((listDeviceKeys as jest.Mock).mock.calls[0][0]).toBe(USER_ID);
  });
});

describe('DELETE /api/v1/devices/keys/:deviceId', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).delete(`/api/v1/devices/keys/${DEVICE_ID}`);
    expect(res.status).toBe(401);
    expect(revokeDeviceKey).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID deviceId', async () => {
    authenticateAs(user);
    const res = await request(app).delete('/api/v1/devices/keys/not-a-uuid').set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(revokeDeviceKey).not.toHaveBeenCalled();
  });

  it('revokes for the owner (compromised-device handling)', async () => {
    authenticateAs(user);
    const res = await request(app).delete(`/api/v1/devices/keys/${DEVICE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(204);
    expect((revokeDeviceKey as jest.Mock).mock.calls[0]).toEqual([USER_ID, DEVICE_ID]);
  });

  it("404s for another user's device key, same as every other owned-resource delete in this codebase", async () => {
    authenticateAs(user);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (revokeDeviceKey as jest.Mock).mockRejectedValue(HttpError.notFound('Device key not found'));
    const res = await request(app).delete(`/api/v1/devices/keys/${DEVICE_ID}`).set('Authorization', 'Bearer t');
    expect(res.status).toBe(404);
  });
});
