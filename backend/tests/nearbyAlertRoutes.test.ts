import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
}));
jest.mock('../src/services/nearbyAlertService', () => ({
  getNearbyPreference: jest.fn(),
  setNearbyPreference: jest.fn(),
  upsertNearbyLocationIfEnabled: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import {
  getNearbyPreference,
  setNearbyPreference,
  upsertNearbyLocationIfEnabled,
} from '../src/services/nearbyAlertService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const authedUser: AuthenticatedUser = {
  id: '11111111-1111-1111-1111-111111111111',
  googleSubject: 'g-1',
  email: 'user@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'User',
  accountStatus: 'active',
};

let nextTestUserSuffix = 1;
function freshAuthedUser(): AuthenticatedUser {
  const suffix = String(nextTestUserSuffix++).padStart(12, '0');
  return { ...authedUser, id: `77777777-7777-7777-7777-${suffix}` };
}

function authenticateAs(user: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('GET /api/v1/nearby-alerts/preference', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/nearby-alerts/preference');
    expect(res.status).toBe(401);
  });

  it('returns the caller\'s own preference, defaulting to disabled', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (getNearbyPreference as jest.Mock).mockResolvedValue({ enabled: false, radiusM: null });

    const res = await request(app).get('/api/v1/nearby-alerts/preference').set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.preference).toEqual({ enabled: false, radiusM: null });
    expect((getNearbyPreference as jest.Mock).mock.calls[0][0]).toBe(user.id);
  });
});

describe('PUT /api/v1/nearby-alerts/preference', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).put('/api/v1/nearby-alerts/preference').send({ enabled: true });
    expect(res.status).toBe(401);
    expect(setNearbyPreference).not.toHaveBeenCalled();
  });

  it('rejects a non-boolean enabled value', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .put('/api/v1/nearby-alerts/preference')
      .set('Authorization', 'Bearer t')
      .send({ enabled: 'yes' });
    expect(res.status).toBe(400);
    expect(setNearbyPreference).not.toHaveBeenCalled();
  });

  it('rejects a radiusM below the allowed minimum', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .put('/api/v1/nearby-alerts/preference')
      .set('Authorization', 'Bearer t')
      .send({ enabled: true, radiusM: 10 });
    expect(res.status).toBe(400);
  });

  it('sets the preference for the authenticated caller', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (setNearbyPreference as jest.Mock).mockResolvedValue({ enabled: true, radiusM: null });

    const res = await request(app)
      .put('/api/v1/nearby-alerts/preference')
      .set('Authorization', 'Bearer t')
      .send({ enabled: true });

    expect(res.status).toBe(200);
    expect((setNearbyPreference as jest.Mock).mock.calls[0][0]).toBe(user.id);
    expect(res.body.preference).toEqual({ enabled: true, radiusM: null });
  });
});

describe('PUT /api/v1/nearby-alerts/location', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).put('/api/v1/nearby-alerts/location').send({ latitude: 1, longitude: 1 });
    expect(res.status).toBe(401);
  });

  it('rejects an out-of-range latitude', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .put('/api/v1/nearby-alerts/location')
      .set('Authorization', 'Bearer t')
      .send({ latitude: 999, longitude: 1 });
    expect(res.status).toBe(400);
    expect(upsertNearbyLocationIfEnabled).not.toHaveBeenCalled();
  });

  it('reports stored=false without erroring when the preference is off', async () => {
    authenticateAs(freshAuthedUser());
    (upsertNearbyLocationIfEnabled as jest.Mock).mockResolvedValue(false);

    const res = await request(app)
      .put('/api/v1/nearby-alerts/location')
      .set('Authorization', 'Bearer t')
      .send({ latitude: 27.7, longitude: 85.3 });

    expect(res.status).toBe(200);
    expect(res.body.stored).toBe(false);
  });

  it('reports stored=true when the preference is on', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (upsertNearbyLocationIfEnabled as jest.Mock).mockResolvedValue(true);

    const res = await request(app)
      .put('/api/v1/nearby-alerts/location')
      .set('Authorization', 'Bearer t')
      .send({ latitude: 27.7, longitude: 85.3 });

    expect(res.status).toBe(200);
    expect(res.body.stored).toBe(true);
    expect((upsertNearbyLocationIfEnabled as jest.Mock).mock.calls[0]).toEqual([user.id, 27.7, 85.3]);
  });
});
