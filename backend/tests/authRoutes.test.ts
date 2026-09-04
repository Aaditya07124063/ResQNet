import request from 'supertest';

jest.mock('../src/services/googleAuthService', () => ({
  verifyGoogleIdToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  findOrCreateUserByGoogleSubject: jest.fn(),
  touchLastLogin: jest.fn(),
  getUserById: jest.fn(),
}));
jest.mock('../src/services/sessionService', () => ({
  issueSession: jest.fn(),
  rotateRefreshToken: jest.fn(),
  revokeRefreshToken: jest.fn(),
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({
  recordAuditEvent: jest.fn().mockResolvedValue(undefined),
}));

import { createApp } from '../src/app';
import { HttpError } from '../src/utils/httpError';
import { verifyGoogleIdToken } from '../src/services/googleAuthService';
import { findOrCreateUserByGoogleSubject, getUserById } from '../src/services/userService';
import { issueSession, rotateRefreshToken, verifyAccessToken } from '../src/services/sessionService';
import type { AuthenticatedUser } from '../src/models/User';

const app = createApp();

const activeUser: AuthenticatedUser = {
  id: 'user-1',
  googleSubject: 'g-1',
  email: 'a@example.com',
  emailVerified: true,
  phoneNumber: null,
  phoneVerified: false,
  displayName: 'A',
  accountStatus: 'active',
};

const fakeSession = {
  accessToken: 'access-token-value',
  accessTokenExpiresAt: new Date('2030-01-01T00:00:00Z'),
  refreshToken: 'refresh-token-value',
  refreshTokenExpiresAt: new Date('2030-02-01T00:00:00Z'),
};

describe('POST /api/v1/auth/google', () => {
  it('rejects a body missing idToken', async () => {
    const res = await request(app).post('/api/v1/auth/google').send({});
    expect(res.status).toBe(400);
  });

  it('rejects an invalid Google ID token (propagated as 401)', async () => {
    (verifyGoogleIdToken as jest.Mock).mockRejectedValue(HttpError.unauthorized('bad token'));
    const res = await request(app)
      .post('/api/v1/auth/google')
      .send({ idToken: 'x'.repeat(30) });
    expect(res.status).toBe(401);
  });

  it('denies a suspended account even with a valid Google token', async () => {
    (verifyGoogleIdToken as jest.Mock).mockResolvedValue({
      subject: 'g-1',
      email: 'a@example.com',
      emailVerified: true,
      displayName: 'A',
    });
    (findOrCreateUserByGoogleSubject as jest.Mock).mockResolvedValue({
      ...activeUser,
      accountStatus: 'suspended',
    });
    const res = await request(app)
      .post('/api/v1/auth/google')
      .send({ idToken: 'x'.repeat(30) });
    expect(res.status).toBe(403);
  });

  it('issues a session for a valid token and active account', async () => {
    (verifyGoogleIdToken as jest.Mock).mockResolvedValue({
      subject: 'g-1',
      email: 'a@example.com',
      emailVerified: true,
      displayName: 'A',
    });
    (findOrCreateUserByGoogleSubject as jest.Mock).mockResolvedValue(activeUser);
    (issueSession as jest.Mock).mockResolvedValue(fakeSession);

    const res = await request(app)
      .post('/api/v1/auth/google')
      .send({ idToken: 'x'.repeat(30) });

    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe('user-1');
    expect(res.body.session.accessToken).toBe('access-token-value');
  });
});

describe('POST /api/v1/auth/refresh', () => {
  it('rejects a missing refreshToken', async () => {
    const res = await request(app).post('/api/v1/auth/refresh').send({});
    expect(res.status).toBe(400);
  });

  it('rejects an invalid/expired refresh token', async () => {
    (rotateRefreshToken as jest.Mock).mockRejectedValue(HttpError.unauthorized('bad refresh token'));
    const res = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: 'x'.repeat(30) });
    expect(res.status).toBe(401);
  });

  it('issues a new session for a valid refresh token', async () => {
    (rotateRefreshToken as jest.Mock).mockResolvedValue(fakeSession);
    const res = await request(app)
      .post('/api/v1/auth/refresh')
      .send({ refreshToken: 'x'.repeat(30) });
    expect(res.status).toBe(200);
    expect(res.body.session.refreshToken).toBe('refresh-token-value');
  });
});

describe('GET /api/v1/me', () => {
  it('denies an unauthenticated request', async () => {
    const res = await request(app).get('/api/v1/me');
    expect(res.status).toBe(401);
  });

  it('returns the authenticated user for a valid token', async () => {
    (verifyAccessToken as jest.Mock).mockReturnValue('user-1');
    (getUserById as jest.Mock).mockResolvedValue(activeUser);
    const res = await request(app).get('/api/v1/me').set('Authorization', 'Bearer valid-token');
    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe('user-1');
  });
});
