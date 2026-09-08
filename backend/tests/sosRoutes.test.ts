import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
}));
jest.mock('../src/services/sosService', () => ({
  createSosEvent: jest.fn(),
  listSosEvents: jest.fn(),
  updateSosEventStatus: jest.fn(),
  getNearbyEmergencyDetail: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import {
  createSosEvent,
  getNearbyEmergencyDetail,
  listSosEvents,
  updateSosEventStatus,
} from '../src/services/sosService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const USER_ID = '11111111-1111-1111-1111-111111111111';
const EVENT_ID = '22222222-2222-2222-2222-222222222222';

const authedUser: AuthenticatedUser = {
  id: USER_ID,
  googleSubject: 'g-1',
  email: 'user@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'User',
  accountStatus: 'active',
};

function authenticateAs(user: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
}

// SOS_RATE_LIMIT_MAX defaults to a strict 5/window, keyed by authenticated
// user id, and the limiter runs before body validation (by design — see
// rateLimiter.ts) — so EVERY authenticated POST /sos in this file,
// including ones that go on to fail validation, consumes one slot. Each
// POST-issuing test below authenticates as its own freshly-numbered user
// so none of them share (and exhaust) another's budget.
let nextTestUserSuffix = 1;
function freshAuthedUser(): AuthenticatedUser {
  const suffix = String(nextTestUserSuffix++).padStart(12, '0');
  return { ...authedUser, id: `99999999-9999-9999-9999-${suffix}` };
}

const VALID_BODY = {
  eventId: EVENT_ID,
  eventSource: 'manual',
  category: 'medical',
  message: 'need help',
  latitude: 12.34,
  longitude: 56.78,
  clientCreatedAt: '2026-01-01T00:00:00.000Z',
};

const FAKE_EVENT = {
  id: 'db-event-1',
  eventId: EVENT_ID,
  eventSource: 'manual',
  category: 'medical',
  message: 'need help',
  latitude: 12.34,
  longitude: 56.78,
  locationAccuracyM: null,
  status: 'open',
  clientCreatedAt: '2026-01-01T00:00:00.000Z',
  serverReceivedAt: '2026-01-01T00:00:01.000Z',
  resolvedAt: null,
};

describe('POST /api/v1/sos', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).post('/api/v1/sos').send(VALID_BODY);
    expect(res.status).toBe(401);
    expect(createSosEvent).not.toHaveBeenCalled();
  });

  it('rejects an invalid eventSource not in the schema CHECK constraint', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post('/api/v1/sos')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, eventSource: 'not_a_real_source' });
    expect(res.status).toBe(400);
    expect(createSosEvent).not.toHaveBeenCalled();
  });

  it('rejects a missing eventId', async () => {
    authenticateAs(freshAuthedUser());
    const withoutId: Record<string, unknown> = { ...VALID_BODY };
    delete withoutId.eventId;
    const res = await request(app).post('/api/v1/sos').set('Authorization', 'Bearer t').send(withoutId);
    expect(res.status).toBe(400);
    expect(createSosEvent).not.toHaveBeenCalled();
  });

  it('rejects an out-of-range latitude', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post('/api/v1/sos')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, latitude: 999 });
    expect(res.status).toBe(400);
    expect(createSosEvent).not.toHaveBeenCalled();
  });

  it('rejects a category longer than the schema column allows (40 chars)', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .post('/api/v1/sos')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, category: 'x'.repeat(41) });
    expect(res.status).toBe(400);
    expect(createSosEvent).not.toHaveBeenCalled();
  });

  it('creates an event for a valid, authenticated request', async () => {
    authenticateAs(freshAuthedUser());
    (createSosEvent as jest.Mock).mockResolvedValue(FAKE_EVENT);

    const res = await request(app).post('/api/v1/sos').set('Authorization', 'Bearer t').send(VALID_BODY);

    expect(res.status).toBe(201);
    expect(res.body.event.id).toBe('db-event-1');
  });

  it('derives the reporter identity from the session, ignoring any client-supplied identity field', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (createSosEvent as jest.Mock).mockResolvedValue(FAKE_EVENT);

    await request(app)
      .post('/api/v1/sos')
      .set('Authorization', 'Bearer t')
      .send({ ...VALID_BODY, userId: 'attacker-controlled-id' });

    expect((createSosEvent as jest.Mock).mock.calls[0][0]).toBe(user.id);
    expect((createSosEvent as jest.Mock).mock.calls[0][1]).not.toHaveProperty('userId');
  });

  it('propagates an event-id-collision conflict from the service as 409', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (createSosEvent as jest.Mock).mockRejectedValue(HttpError.conflict('This SOS event id is already in use'));

    const res = await request(app).post('/api/v1/sos').set('Authorization', 'Bearer t').send(VALID_BODY);

    expect(res.status).toBe(409);
  });

  it('rate-limits repeated SOS submissions from the same user', async () => {
    // A dedicated user id — sosRateLimiter is a module-level singleton
    // whose counter would otherwise carry over from earlier requests
    // above and make this test depend on execution order/count.
    const rateLimitTestUser: AuthenticatedUser = { ...authedUser, id: '33333333-3333-3333-3333-333333333333' };
    authenticateAs(rateLimitTestUser);
    (createSosEvent as jest.Mock).mockResolvedValue(FAKE_EVENT);

    // SOS_RATE_LIMIT_MAX defaults to 5 per window.
    let lastStatus = 0;
    for (let i = 0; i < 6; i++) {
      const res = await request(app)
        .post('/api/v1/sos')
        .set('Authorization', 'Bearer t')
        .send({ ...VALID_BODY, eventId: `33333333-3333-3333-3333-33333333330${i}` });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});

describe('GET /api/v1/sos', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/sos');
    expect(res.status).toBe(401);
  });

  it('returns the authenticated user\'s own events', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (listSosEvents as jest.Mock).mockResolvedValue([FAKE_EVENT]);

    const res = await request(app).get('/api/v1/sos').set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.events).toEqual([FAKE_EVENT]);
    expect((listSosEvents as jest.Mock).mock.calls[0][0]).toBe(user.id);
  });
});

describe('PATCH /api/v1/sos/:id', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).patch(`/api/v1/sos/${FAKE_EVENT.id}`).send({ status: 'resolved' });
    expect(res.status).toBe(401);
  });

  it('rejects an invalid status value ("open" is not a valid client-chosen transition)', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .patch(`/api/v1/sos/${EVENT_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'open' });
    expect(res.status).toBe(400);
    expect(updateSosEventStatus).not.toHaveBeenCalled();
  });

  it('rejects a non-UUID id param', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .patch('/api/v1/sos/not-a-uuid')
      .set('Authorization', 'Bearer t')
      .send({ status: 'resolved' });
    expect(res.status).toBe(400);
    expect(updateSosEventStatus).not.toHaveBeenCalled();
  });

  it('updates status for a valid, authenticated request', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (updateSosEventStatus as jest.Mock).mockResolvedValue({ ...FAKE_EVENT, status: 'resolved' });

    const res = await request(app)
      .patch(`/api/v1/sos/${EVENT_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'resolved' });

    expect(res.status).toBe(200);
    expect(res.body.event.status).toBe('resolved');
    expect((updateSosEventStatus as jest.Mock).mock.calls[0]).toEqual([user.id, EVENT_ID, { status: 'resolved' }]);
  });

  it('propagates a not-found error from the service as 404', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (updateSosEventStatus as jest.Mock).mockRejectedValue(HttpError.notFound('SOS event not found'));

    const res = await request(app)
      .patch(`/api/v1/sos/${EVENT_ID}`)
      .set('Authorization', 'Bearer t')
      .send({ status: 'resolved' });

    expect(res.status).toBe(404);
  });
});

describe('GET /api/v1/sos/:id/nearby-detail', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get(`/api/v1/sos/${EVENT_ID}/nearby-detail`);
    expect(res.status).toBe(401);
  });

  it('rejects a non-UUID id param', async () => {
    authenticateAs(freshAuthedUser());
    const res = await request(app)
      .get('/api/v1/sos/not-a-uuid/nearby-detail')
      .set('Authorization', 'Bearer t');
    expect(res.status).toBe(400);
    expect(getNearbyEmergencyDetail).not.toHaveBeenCalled();
  });

  it('returns the minimal detail for an authorized nearby recipient', async () => {
    const user = freshAuthedUser();
    authenticateAs(user);
    (getNearbyEmergencyDetail as jest.Mock).mockResolvedValue({
      sosEventId: EVENT_ID,
      category: 'medical',
      status: 'open',
      approximateDistance: 'Within 1 km',
      activatedAt: '2026-01-01T00:00:01.000Z',
    });

    const res = await request(app).get(`/api/v1/sos/${EVENT_ID}/nearby-detail`).set('Authorization', 'Bearer t');

    expect(res.status).toBe(200);
    expect(res.body.detail).not.toHaveProperty('latitude');
    expect(res.body.detail).not.toHaveProperty('longitude');
    expect(res.body.detail).not.toHaveProperty('reporterName');
    expect((getNearbyEmergencyDetail as jest.Mock).mock.calls[0]).toEqual([user.id, EVENT_ID]);
  });

  it('404s (IDOR protection) when the caller was never a nearby recipient of this event', async () => {
    authenticateAs(freshAuthedUser());
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (getNearbyEmergencyDetail as jest.Mock).mockRejectedValue(HttpError.notFound('Emergency not found'));

    const res = await request(app).get(`/api/v1/sos/${EVENT_ID}/nearby-detail`).set('Authorization', 'Bearer t');

    expect(res.status).toBe(404);
  });
});
