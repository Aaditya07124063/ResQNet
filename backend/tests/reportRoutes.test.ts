import request from 'supertest';

jest.mock('../src/services/sessionService', () => ({
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
}));
jest.mock('../src/services/reportService', () => ({
  createReport: jest.fn(),
}));

import { createApp } from '../src/app';
import { verifyAccessToken } from '../src/services/sessionService';
import { getUserById } from '../src/services/userService';
import { createReport } from '../src/services/reportService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const REPORTER_ID = '11111111-1111-1111-1111-111111111111';
const TARGET_ID = '22222222-2222-2222-2222-222222222222';

const reporterUser: AuthenticatedUser = {
  id: REPORTER_ID,
  googleSubject: 'g-1',
  email: 'reporter@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'Reporter',
  accountStatus: 'active',
};

function authenticateAs(user: AuthenticatedUser) {
  (verifyAccessToken as jest.Mock).mockReturnValue(user.id);
  (getUserById as jest.Mock).mockResolvedValue(user);
}

describe('POST /api/v1/reports', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app)
      .post('/api/v1/reports')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment' });
    expect(res.status).toBe(401);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('rejects an invalid (non-UUID) target id', async () => {
    authenticateAs(reporterUser);
    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: 'not-a-uuid', reason: 'harassment' });
    expect(res.status).toBe(400);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('rejects a missing reason', async () => {
    authenticateAs(reporterUser);
    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID });
    expect(res.status).toBe(400);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('rejects a missing reportedUserId', async () => {
    authenticateAs(reporterUser);
    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reason: 'harassment' });
    expect(res.status).toBe(400);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('rejects a reason longer than the schema column allows (60 chars)', async () => {
    authenticateAs(reporterUser);
    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'x'.repeat(61) });
    expect(res.status).toBe(400);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('rejects an oversized description', async () => {
    authenticateAs(reporterUser);
    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment', description: 'x'.repeat(2001) });
    expect(res.status).toBe(400);
    expect(createReport).not.toHaveBeenCalled();
  });

  it('creates a report for a valid, authenticated request', async () => {
    authenticateAs(reporterUser);
    (createReport as jest.Mock).mockResolvedValue({
      id: 'report-1',
      reportedUserId: TARGET_ID,
      reason: 'harassment',
      description: null,
      status: 'open',
      createdAt: '2026-01-01T00:00:00.000Z',
    });

    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment' });

    expect(res.status).toBe(201);
    expect(res.body.report.id).toBe('report-1');
    expect(res.body.report).not.toHaveProperty('reporterUserId');
  });

  it('derives the reporter identity from the session, ignoring any client-supplied identity field (cannot be spoofed)', async () => {
    authenticateAs(reporterUser);
    (createReport as jest.Mock).mockResolvedValue({
      id: 'report-1',
      reportedUserId: TARGET_ID,
      reason: 'harassment',
      description: null,
      status: 'open',
      createdAt: '2026-01-01T00:00:00.000Z',
    });

    await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({
        reportedUserId: TARGET_ID,
        reason: 'harassment',
        // Attempted spoof — not part of the schema, silently stripped by
        // validation, and never consulted for identity regardless.
        reporterUserId: 'attacker-controlled-id',
      });

    // The first argument to createReport is ALWAYS req.authUser.id, sourced
    // from the verified session — never anything from the request body.
    expect((createReport as jest.Mock).mock.calls[0][0]).toBe(REPORTER_ID);
    expect((createReport as jest.Mock).mock.calls[0][1]).not.toHaveProperty('reporterUserId');
  });

  it('propagates a duplicate-report conflict from the service as 409', async () => {
    authenticateAs(reporterUser);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (createReport as jest.Mock).mockRejectedValue(
      HttpError.conflict('You already have an open report against this user'),
    );

    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment' });

    expect(res.status).toBe(409);
  });

  it('propagates a nonexistent-target error from the service as 400', async () => {
    authenticateAs(reporterUser);
    const { HttpError } = jest.requireActual('../src/utils/httpError');
    (createReport as jest.Mock).mockRejectedValue(HttpError.badRequest('Report target does not exist'));

    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment' });

    expect(res.status).toBe(400);
  });

  it('surfaces an unexpected database failure as a safe 500, not raw DB details', async () => {
    authenticateAs(reporterUser);
    (createReport as jest.Mock).mockRejectedValue(new Error('connection terminated unexpectedly'));

    const res = await request(app)
      .post('/api/v1/reports')
      .set('Authorization', 'Bearer t')
      .send({ reportedUserId: TARGET_ID, reason: 'harassment' });

    expect(res.status).toBe(500);
  });

  it('rate-limits repeated report submissions from the same user', async () => {
    // A dedicated user id, never used by any other test in this file —
    // reportRateLimiter is a module-level singleton whose counter would
    // otherwise carry over from every earlier authenticated request above
    // and make this test's outcome depend on execution order/count.
    const rateLimitTestUser: AuthenticatedUser = {
      ...reporterUser,
      id: '33333333-3333-3333-3333-333333333333',
    };
    authenticateAs(rateLimitTestUser);
    (createReport as jest.Mock).mockResolvedValue({
      id: 'report-1',
      reportedUserId: TARGET_ID,
      reason: 'harassment',
      description: null,
      status: 'open',
      createdAt: '2026-01-01T00:00:00.000Z',
    });

    // REPORT_RATE_LIMIT_MAX defaults to 10 per window — the 11th request
    // from the same authenticated user in the same window must be denied.
    let lastStatus = 0;
    for (let i = 0; i < 11; i++) {
      const res = await request(app)
        .post('/api/v1/reports')
        .set('Authorization', 'Bearer t')
        .send({ reportedUserId: TARGET_ID, reason: 'harassment' });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});
