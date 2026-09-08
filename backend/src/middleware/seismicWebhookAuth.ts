import { timingSafeEqual } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';
import { HttpError } from '../utils/httpError';
import { env } from '../config/env';

const HEADER_NAME = 'x-seismic-webhook-secret';

// Constant-time comparison — a length mismatch alone must never
// short-circuit before the timing-safe compare, so a same-length dummy
// compare always runs first regardless of the outcome.
function safeEqual(provided: string, expected: string): boolean {
  const providedBuf = Buffer.from(provided);
  const expectedBuf = Buffer.from(expected);
  if (providedBuf.length !== expectedBuf.length) {
    timingSafeEqual(providedBuf, providedBuf);
    return false;
  }
  return timingSafeEqual(providedBuf, expectedBuf);
}

/**
 * Gates POST /api/v1/internal/seismic-alerts. The only caller is
 * functions/index.js's `correlateSeismicEvent` Cloud Function — a
 * service, not a ResQNet user or employee session — so this checks a
 * shared secret header instead of requireAuth/requireEmployeeAuth's JWTs.
 *
 * Never logs the header value or the configured secret, on any path
 * (missing config, missing header, or mismatch).
 */
export function requireSeismicWebhookAuth(req: Request, _res: Response, next: NextFunction): void {
  if (!env.SEISMIC_WEBHOOK_SECRET) {
    next(new HttpError(503, 'NOT_CONFIGURED', 'Seismic alert webhook is not configured'));
    return;
  }

  const provided = req.header(HEADER_NAME);
  if (!provided || !safeEqual(provided, env.SEISMIC_WEBHOOK_SECRET)) {
    next(HttpError.unauthorized('Invalid webhook secret'));
    return;
  }

  next();
}
