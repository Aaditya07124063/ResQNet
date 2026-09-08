import request from 'supertest';

jest.mock('../src/services/googleAuthService', () => ({
  verifyGoogleIdToken: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  findOrCreateUserByGoogleSubject: jest.fn(),
  findOrCreateUserByPhone: jest.fn(),
  touchLastLogin: jest.fn(),
  getUserById: jest.fn(),
}));
jest.mock('../src/services/sessionService', () => ({
  issueSession: jest.fn(),
  rotateRefreshToken: jest.fn(),
  revokeRefreshToken: jest.fn(),
  verifyAccessToken: jest.fn(),
}));
jest.mock('../src/services/verificationService', () => ({
  requestOtp: jest.fn(),
  verifyOtp: jest.fn(),
}));
jest.mock('../src/services/sms/smsService', () => ({
  sendSms: jest.fn(),
}));
jest.mock('../src/services/auditLogService', () => ({
  recordAuditEvent: jest.fn().mockResolvedValue(undefined),
}));

import { createApp } from '../src/app';
import { HttpError } from '../src/utils/httpError';
import { verifyGoogleIdToken } from '../src/services/googleAuthService';
import { findOrCreateUserByGoogleSubject, findOrCreateUserByPhone, getUserById } from '../src/services/userService';
import { issueSession, rotateRefreshToken, verifyAccessToken } from '../src/services/sessionService';
import { requestOtp, verifyOtp } from '../src/services/verificationService';
import { sendSms } from '../src/services/sms/smsService';
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

// Phone-OTP auth (Step 2 of the Firebase migration). otpSendIpRateLimiter/
// otpVerifyRateLimiter are module-level singletons keyed by req.ip — since
// TRUSTED_PROXY_HOPS defaults to 1, Express honors X-Forwarded-For, so
// every test below that ISN'T specifically exercising the IP rate limiter
// sets a distinct X-Forwarded-For to avoid sharing a rate-limit bucket
// with other tests in this file (mirrors sosRoutes.test.ts's own
// dedicated-user-id trick for its user-keyed limiter).
const phoneUser: AuthenticatedUser = {
  id: 'user-phone-1',
  googleSubject: null,
  email: null,
  emailVerified: false,
  phoneNumber: '+9779812345678',
  phoneVerified: true,
  displayName: null,
  accountStatus: 'active',
};

describe('POST /api/v1/auth/phone/send-otp', () => {
  it('rejects a malformed phone number', async () => {
    const res = await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.1')
      .send({ phoneNumber: 'not-a-phone-number' });
    expect(res.status).toBe(400);
    expect(requestOtp).not.toHaveBeenCalled();
  });

  // otpSendPhoneRateLimiter (max 3 per 15-minute window by default) is
  // ALSO a shared bucket across every test in this file that sends the
  // same phone number — unlike the IP limiter above, varying
  // X-Forwarded-For does nothing for it. Each functional test below uses
  // its own distinct phone number so it doesn't silently borrow budget
  // from (or donate budget to) another test; only the tests that
  // specifically exercise the phone-keyed limiter deliberately reuse one
  // number.
  it('normalizes the phone number to E.164 before requesting an OTP', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.2')
      .send({ phoneNumber: '9812345671' });

    expect(requestOtp).toHaveBeenCalledWith(
      expect.objectContaining({ channel: 'sms', target: '+9779812345671', purpose: 'login' }),
    );
    expect(sendSms).toHaveBeenCalledWith('+9779812345671', expect.stringContaining('123456'));
  });

  it('returns a generic success response that never reveals account existence', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    const res = await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.3')
      .send({ phoneNumber: '9812345672' });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ message: 'If eligible, a code was sent.' });
  });

  it('never returns the OTP code in the response body', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '654321' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    const res = await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.4')
      .send({ phoneNumber: '9812345673' });

    expect(JSON.stringify(res.body)).not.toContain('654321');
  });

  it('propagates an SMS-send failure as a 500 without leaking provider details', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockRejectedValue(HttpError.internal('SMS delivery is not currently available'));

    const res = await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.5')
      .send({ phoneNumber: '9812345674' });

    expect(res.status).toBe(500);
    expect(JSON.stringify(res.body)).not.toMatch(/sparrow|token/i);
  });

  it('surfaces the 60-second resend cooldown as a 429', async () => {
    (requestOtp as jest.Mock).mockRejectedValue(HttpError.tooManyRequests('Please wait before requesting another code'));

    const res = await request(app)
      .post('/api/v1/auth/phone/send-otp')
      .set('X-Forwarded-For', '10.0.1.6')
      .send({ phoneNumber: '9812345675' });

    expect(res.status).toBe(429);
  });

  it('rate-limits repeated requests from the same IP (OTP_SEND_RATE_LIMIT_MAX defaults to 3)', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    // A single fixed phone number reused across this loop's 4 requests
    // would ALSO trip the phone-keyed limiter, making it ambiguous which
    // limiter actually produced the 429 — vary the phone number per
    // request (fixed IP) so only the IP limiter can be responsible here.
    let lastStatus = 0;
    for (let i = 0; i < 4; i++) {
      const res = await request(app)
        .post('/api/v1/auth/phone/send-otp')
        .set('X-Forwarded-For', '10.0.2.1')
        .send({ phoneNumber: `981234568${i}` });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });

  it('rate-limits repeated requests for the same phone number even across different IPs', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    let lastStatus = 0;
    for (let i = 0; i < 4; i++) {
      const res = await request(app)
        .post('/api/v1/auth/phone/send-otp')
        .set('X-Forwarded-For', `10.0.3.${i}`) // distinct IP each time — isolates from the IP limiter
        .send({ phoneNumber: '9800000000' }); // same phone every time
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });

  it('rate limiting is immune to formatting-variant bypass (same number, different formatting)', async () => {
    (requestOtp as jest.Mock).mockResolvedValue({ code: '123456' });
    (sendSms as jest.Mock).mockResolvedValue(undefined);

    const variants = ['9811111111', '+977 981 111 1111', '+977-981-111-1111', '9811111111'];
    let lastStatus = 0;
    for (let i = 0; i < variants.length; i++) {
      const res = await request(app)
        .post('/api/v1/auth/phone/send-otp')
        .set('X-Forwarded-For', `10.0.4.${i}`)
        .send({ phoneNumber: variants[i] });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});

describe('POST /api/v1/auth/phone/verify-otp', () => {
  it('rejects a malformed phone number', async () => {
    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.1')
      .send({ phoneNumber: 'not-a-phone', code: '123456' });
    expect(res.status).toBe(400);
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it('rejects a code that is not exactly 6 digits', async () => {
    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.2')
      .send({ phoneNumber: '9812345678', code: '12345' });
    expect(res.status).toBe(400);
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it('rejects a non-numeric code', async () => {
    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.3')
      .send({ phoneNumber: '9812345678', code: 'abcdef' });
    expect(res.status).toBe(400);
  });

  it('returns a generic 401 for an invalid/expired/consumed/wrong code', async () => {
    (verifyOtp as jest.Mock).mockResolvedValue({ outcome: 'invalid' });

    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.4')
      .send({ phoneNumber: '9812345678', code: '123456' });

    expect(res.status).toBe(401);
    expect(findOrCreateUserByPhone).not.toHaveBeenCalled();
  });

  it('creates the user, sets phone_verified, and issues a session on successful verification', async () => {
    (verifyOtp as jest.Mock).mockResolvedValue({ outcome: 'verified' });
    (findOrCreateUserByPhone as jest.Mock).mockResolvedValue(phoneUser);
    (issueSession as jest.Mock).mockResolvedValue(fakeSession);

    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.5')
      .send({ phoneNumber: '9812345678', code: '123456' });

    expect(res.status).toBe(200);
    expect(findOrCreateUserByPhone).toHaveBeenCalledWith('+9779812345678');
    expect(res.body.user.phoneVerified).toBe(true);
    expect(res.body.session.accessToken).toBe('access-token-value');
    expect(res.body.session.refreshToken).toBe('refresh-token-value');
  });

  it('logs in an existing verified user (no re-creation) on a later successful verification', async () => {
    (verifyOtp as jest.Mock).mockResolvedValue({ outcome: 'verified' });
    (findOrCreateUserByPhone as jest.Mock).mockResolvedValue(phoneUser);
    (issueSession as jest.Mock).mockResolvedValue(fakeSession);

    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.6')
      .send({ phoneNumber: '9812345678', code: '123456' });

    expect(res.status).toBe(200);
    expect(res.body.user.id).toBe('user-phone-1');
  });

  it('denies a suspended account even with a correct code', async () => {
    (verifyOtp as jest.Mock).mockResolvedValue({ outcome: 'verified' });
    (findOrCreateUserByPhone as jest.Mock).mockResolvedValue({ ...phoneUser, accountStatus: 'suspended' });

    const res = await request(app)
      .post('/api/v1/auth/phone/verify-otp')
      .set('X-Forwarded-For', '10.0.5.7')
      .send({ phoneNumber: '9812345678', code: '123456' });

    expect(res.status).toBe(403);
    expect(issueSession).not.toHaveBeenCalled();
  });

  it('rate-limits repeated verify attempts from the same IP (OTP_VERIFY_RATE_LIMIT_MAX defaults to 10)', async () => {
    (verifyOtp as jest.Mock).mockResolvedValue({ outcome: 'invalid' });

    let lastStatus = 0;
    for (let i = 0; i < 11; i++) {
      const res = await request(app)
        .post('/api/v1/auth/phone/verify-otp')
        .set('X-Forwarded-For', '10.0.6.1')
        .send({ phoneNumber: '9812345678', code: '123456' });
      lastStatus = res.status;
    }
    expect(lastStatus).toBe(429);
  });
});
