import type { ErrorRequestHandler, RequestHandler } from 'express';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { isProduction } from '../config/env';

// Central error handler. Never returns stack traces, raw DB errors, or
// secrets to the client — those go to the server log only.
export const errorHandler: ErrorRequestHandler = (err, req, res, _next) => {
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
