import rateLimit from 'express-rate-limit';
import { env } from '../config/env';
import { HttpError } from '../utils/httpError';

// Default limiter for general API traffic. Keyed by authenticated user when
// available (post requireAuth), falling back to IP for unauthenticated routes.
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
