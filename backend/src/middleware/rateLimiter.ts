import rateLimit from 'express-rate-limit';
import { env } from '../config/env';
import { HttpError } from '../utils/httpError';

// Default limiter for general API traffic — mounted in app.ts BEFORE the
// route-level `requireAuth` middleware ever runs, so `req.authUser` is
// always undefined here in practice; this is always IP-keyed. (Corrected
// during the Phase 19 security audit — the comment previously claimed
// user-keying, which never actually happened. The route-specific limiters
// below (sos/report/device/employee) DO run after their own requireAuth
// and are genuinely user-keyed.)
export const defaultRateLimiter = rateLimit({
  windowMs: env.RATE_LIMIT_WINDOW_MS,
  max: env.RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests()),
});

// Stricter limiter for SOS creation specifically (Phase 9/11): SOS is
// high-stakes but also the most abuse-sensitive endpoint (flooding would
// drown out real emergencies), so it gets its own tighter budget.
export const sosRateLimiter = rateLimit({
  windowMs: env.SOS_RATE_LIMIT_WINDOW_MS,
  max: env.SOS_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) =>
    next(HttpError.tooManyRequests('Too many SOS requests — please wait before retrying')),
});

// Tighter limiter for report creation (Phase 14): reports are rarer than
// general API traffic, and flooding reports against one user is exactly
// the abuse pattern the threshold/review-case design needs protecting
// from — keyed by the reporting user, not the target.
export const reportRateLimiter = rateLimit({
  windowMs: env.REPORT_RATE_LIMIT_WINDOW_MS,
  max: env.REPORT_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) =>
    next(HttpError.tooManyRequests('Too many reports submitted — please wait before retrying')),
});

// Limiter for device-token registration/deletion (Phase 17). Generous
// relative to SOS/report — legitimate multi-device use (a user with a
// phone, a tablet, re-registering after every app reopen/token refresh)
// must not be broken by this, so it's keyed by authenticated user with a
// higher budget than the abuse-sensitive endpoints above.
export const deviceRateLimiter = rateLimit({
  windowMs: env.RATE_LIMIT_WINDOW_MS,
  max: 30,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many device registration requests')),
});

// Message sending (communication phase): keyed by authenticated user,
// generous relative to SOS/reports since normal chat is much
// higher-frequency by nature, but still bounded — an unbounded send
// endpoint is a spam/DoS vector against the recipient and the WebSocket
// fan-out path.
export const messageRateLimiter = rateLimit({
  windowMs: env.MESSAGE_RATE_LIMIT_WINDOW_MS,
  max: env.MESSAGE_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many messages sent — please slow down')),
});

// Conversation creation (communication phase): much rarer than sending a
// message within an existing conversation, so a tighter budget.
export const conversationRateLimiter = rateLimit({
  windowMs: env.CONVERSATION_RATE_LIMIT_WINDOW_MS,
  max: env.CONVERSATION_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many conversations created — please wait before retrying')),
});

// Nearby-alert preference/location-ping/detail endpoints: none of these
// should be called often by a legitimate client (a preference toggle, an
// occasional location ping, opening one emergency detail screen) — this
// exists to bound abuse (e.g. hammering the location-ping endpoint), not
// to constrain real usage.
export const nearbyAlertRateLimiter = rateLimit({
  windowMs: env.NEARBY_ALERT_RATE_LIMIT_WINDOW_MS,
  max: env.NEARBY_ALERT_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.authUser?.id ?? req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many requests — please wait before retrying')),
});

// Tighter limiter for unauthenticated auth endpoints (Google/phone
// sign-in, refresh) — keyed by IP since there's no authUser yet, guards
// against credential-stuffing / token-guessing traffic.
export const authRateLimiter = rateLimit({
  windowMs: 60_000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many authentication attempts')),
});

// Stricter limiter for the employee-portal login endpoint specifically
// (Phase 15): a password-based login is a classic credential-stuffing/
// brute-force target, and employee accounts are the highest-privilege
// identity in this system — keyed by IP since there's no authEmployee yet.
export const employeeAuthRateLimiter = rateLimit({
  windowMs: env.EMPLOYEE_AUTH_RATE_LIMIT_WINDOW_MS,
  max: env.EMPLOYEE_AUTH_RATE_LIMIT_MAX,
  standardHeaders: true,
  legacyHeaders: false,
  keyGenerator: (req) => req.ip ?? 'unknown',
  handler: (_req, _res, next) => next(HttpError.tooManyRequests('Too many employee authentication attempts')),
});
