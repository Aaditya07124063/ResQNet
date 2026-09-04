import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { validateBody } from '../middleware/validate';
import { authRateLimiter } from '../middleware/rateLimiter';
import { requireAuth } from '../middleware/authMiddleware';
import { googleSignInSchema, refreshSchema } from '../validation/authSchemas';
import { verifyGoogleIdToken } from '../services/googleAuthService';
import { findOrCreateUserByGoogleSubject, touchLastLogin } from '../services/userService';
import { issueSession, revokeRefreshToken, rotateRefreshToken } from '../services/sessionService';
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

// Phone-OTP sign-in intentionally does NOT live here yet: it depends on
// the SMS provider system (Phase 8/9) to actually deliver a code. Building
// a phone endpoint now would mean either silently no-op'ing or logging
// OTPs, both of which this project explicitly disallows — see
// docs/PLAN.md Phase 4.

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
