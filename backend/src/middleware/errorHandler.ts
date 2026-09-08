import type { ErrorRequestHandler, RequestHandler } from 'express';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { isProduction } from '../config/env';

// Central error handler. Never returns stack traces, raw DB errors, or
// secrets to the client — those go to the server log only.
export const errorHandler: ErrorRequestHandler = (err, req, res, _next) => {
  // express.raw()/express.json() reject an oversized body by throwing
  // before any route handler runs (used by the profile-image upload
  // route's server-side size limit) — surface that as a proper 413
  // instead of falling through to the generic 500 below.
  if ((err as { type?: string }).type === 'entity.too.large') {
    logger.warn({ path: req.path, method: req.method }, 'Request rejected: payload too large');
    res.status(413).json({ error: { code: 'PAYLOAD_TOO_LARGE', message: 'Payload too large' } });
    return;
  }

  // express.json() throws this (via body-parser, an http-errors instance
  // with status 400 masquerading as a SyntaxError) when the request body
  // isn't valid JSON — a client mistake, not a server fault, so this must
  // not fall through to the generic 500 branch below.
  if ((err as { type?: string }).type === 'entity.parse.failed') {
    logger.warn({ path: req.path, method: req.method }, 'Request rejected: malformed JSON body');
    res.status(400).json({ error: { code: 'INVALID_JSON', message: 'Malformed JSON body' } });
    return;
  }

  if (err instanceof HttpError) {
    if (err.status >= 500) {
      logger.error({ err, path: req.path, method: req.method }, 'Request failed');
    } else {
      logger.warn({ code: err.code, path: req.path, method: req.method }, 'Request rejected');
    }
    res.status(err.status).json({
      error: { code: err.code, message: err.message },
    });
    return;
  }

  logger.error({ err, path: req.path, method: req.method }, 'Unhandled error');
  res.status(500).json({
    error: {
      code: 'INTERNAL_ERROR',
      message: isProduction ? 'Internal server error' : (err as Error).message,
    },
  });
};

export const notFoundHandler: RequestHandler = (req, res) => {
  res.status(404).json({ error: { code: 'NOT_FOUND', message: `No route for ${req.method} ${req.path}` } });
};
