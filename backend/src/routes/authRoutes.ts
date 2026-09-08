import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { validateBody } from '../middleware/validate';
import {
  authRateLimiter,
  otpSendIpRateLimiter,
  otpSendPhoneRateLimiter,
  otpVerifyRateLimiter,
} from '../middleware/rateLimiter';
import { requireAuth } from '../middleware/authMiddleware';
import { googleSignInSchema, refreshSchema, sendOtpSchema, verifyOtpSchema } from '../validation/authSchemas';
import { verifyGoogleIdToken } from '../services/googleAuthService';
import { findOrCreateUserByGoogleSubject, findOrCreateUserByPhone, touchLastLogin } from '../services/userService';
import { issueSession, revokeRefreshToken, rotateRefreshToken } from '../services/sessionService';
import { requestOtp, verifyOtp } from '../services/verificationService';
import { sendSms } from '../services/sms/smsService';
import { recordAuditEvent } from '../services/auditLogService';
import { HttpError } from '../utils/httpError';

export const authRouter = Router();

function requestContext(req: import('express').Request) {
  return { userAgent: req.header('user-agent') ?? null, ipAddress: req.ip ?? null };
}

function sessionResponse(session: Awaited<ReturnType<typeof issueSession>>) {
  return {
    accessToken: session.accessToken,
    accessTokenExpiresAt: session.accessTokenExpiresAt.toISOString(),
    refreshToken: session.refreshToken,
    refreshTokenExpiresAt: session.refreshTokenExpiresAt.toISOString(),
  };
}

// Step 2 of the Firebase-removal migration: backend-controlled phone OTP,
// replacing Firebase's verifyPhoneNumber. Both routes reuse the exact
// session-issuance path as /google above (issueSession/sessionResponse) —
// deliberately NOT a second JWT/session mechanism.
//
// 'login' is used as the verification_attempts.purpose for both routes
// (rather than distinguishing 'signup'/'login') because this single flow
// covers both transparently — the account is found-or-created only AFTER
// a successful verify (see findOrCreateUserByPhone), so there's no
// meaningful "signup vs login" branch at OTP-request time to encode.

const OTP_MESSAGE_TEMPLATE = (code: string) => `Your ResQNet verification code is ${code}. It expires in 5 minutes.`;

authRouter.post(
  '/phone/send-otp',
  otpSendIpRateLimiter,
  validateBody(sendOtpSchema),
  otpSendPhoneRateLimiter,
  asyncHandler(async (req, res) => {
    const { phoneNumber } = req.body as { phoneNumber: string }; // already E.164-normalized by sendOtpSchema

    const { code } = await requestOtp({
      channel: 'sms',
      target: phoneNumber,
      purpose: 'login',
      ipAddress: req.ip ?? null,
    });

    // The verification_attempts row above is written BEFORE the send is
    // attempted and is NEVER rolled back if the send below fails — this is
    // a deliberate choice (documented in the Step 2 final report): it
    // means the 60s resend cooldown and the row's own attempt budget apply
    // even to a failed send, closing off a retry-loop that would otherwise
    // let a client force unlimited outbound SMS attempts against the
    // provider by intentionally, or incidentally, triggering repeated
    // failures. The cost is that a genuine one-off provider outage forces
    // the caller to wait out the cooldown before trying again — accepted
    // as the safer failure mode for an abuse-sensitive, cost-bearing
    // (per-SMS-billed) send path.
    try {
      await sendSms(phoneNumber, OTP_MESSAGE_TEMPLATE(code));
    } catch (err) {
      await recordAuditEvent({
        action: 'auth.phone_send_otp',
        resourceType: 'verification_attempt',
        outcome: 'error',
        ipAddress: req.ip,
      });
      throw err;
    }

    await recordAuditEvent({
      action: 'auth.phone_send_otp',
      resourceType: 'verification_attempt',
      outcome: 'success',
      ipAddress: req.ip,
    });

    // Deliberately generic — never reveals whether phoneNumber is already
    // associated with an account (no users row is created at this stage
    // at all, so there is nothing account-specific to leak here).
    res.json({ message: 'If eligible, a code was sent.' });
  }),
);

authRouter.post(
  '/phone/verify-otp',
  otpVerifyRateLimiter,
  validateBody(verifyOtpSchema),
  asyncHandler(async (req, res) => {
    const { phoneNumber, code } = req.body as { phoneNumber: string; code: string };

    const result = await verifyOtp({ channel: 'sms', target: phoneNumber, purpose: 'login', code });
    if (result.outcome !== 'verified') {
      await recordAuditEvent({
        action: 'auth.phone_verify_otp',
        resourceType: 'session',
        outcome: 'denied',
        ipAddress: req.ip,
      });
      // Deliberately the SAME generic message regardless of why the
      // attempt was rejected (no row, wrong code, expired, already
      // consumed, or attempts exhausted) — see verificationService.ts's
      // verifyOtp() doc comment.
      throw HttpError.unauthorized('Invalid or expired code');
    }

    const user = await findOrCreateUserByPhone(phoneNumber);

    if (user.accountStatus === 'suspended' || user.accountStatus === 'deleted') {
      await recordAuditEvent({
        actorUserId: user.id,
        action: 'auth.phone_verify_otp',
        resourceType: 'session',
        outcome: 'denied',
        ipAddress: req.ip,
      });
      throw HttpError.forbidden('This account is not active');
    }

    await touchLastLogin(user.id);
    const session = await issueSession(user.id, requestContext(req));

    await recordAuditEvent({
      actorUserId: user.id,
      action: 'auth.phone_verify_otp',
      resourceType: 'session',
      outcome: 'success',
      ipAddress: req.ip,
    });

    res.json({ user, session: sessionResponse(session) });
  }),
);

authRouter.post(
  '/google',
  authRateLimiter,
  validateBody(googleSignInSchema),
  asyncHandler(async (req, res) => {
    const { idToken } = req.body as { idToken: string };
    const identity = await verifyGoogleIdToken(idToken);

    const user = await findOrCreateUserByGoogleSubject(identity.subject, {
      email: identity.email,
      emailVerified: identity.emailVerified,
      displayName: identity.displayName,
    });

    if (user.accountStatus === 'suspended' || user.accountStatus === 'deleted') {
      await recordAuditEvent({
        actorUserId: user.id,
        action: 'auth.google_sign_in',
        resourceType: 'session',
        outcome: 'denied',
        ipAddress: req.ip,
      });
      throw HttpError.forbidden('This account is not active');
    }

    await touchLastLogin(user.id);
    const session = await issueSession(user.id, requestContext(req));

    await recordAuditEvent({
      actorUserId: user.id,
      action: 'auth.google_sign_in',
      resourceType: 'session',
      outcome: 'success',
      ipAddress: req.ip,
    });

    res.json({ user, session: sessionResponse(session) });
  }),
);

authRouter.post(
  '/refresh',
  authRateLimiter,
  validateBody(refreshSchema),
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body as { refreshToken: string };
    const session = await rotateRefreshToken(refreshToken, requestContext(req));
    res.json({ session: sessionResponse(session) });
  }),
);

authRouter.post(
  '/logout',
  requireAuth,
  validateBody(refreshSchema),
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body as { refreshToken: string };
    await revokeRefreshToken(refreshToken);
    await recordAuditEvent({
      actorUserId: req.authUser!.id,
      action: 'auth.logout',
      resourceType: 'session',
      outcome: 'success',
      ipAddress: req.ip,
    });
    res.status(204).send();
  }),
);
