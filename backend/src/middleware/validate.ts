import type { NextFunction, Request, RequestHandler, Response } from 'express';
import type { ZodType } from 'zod';
import { HttpError } from '../utils/httpError';

/** Validates req.body against `schema`, replacing it with the parsed
 * (typed, stripped-of-unknown-fields) result. Rejects with 400 on failure —
 * request validation happens before any handler logic runs, per the
 * project's "every write endpoint must validate input" rule. */
export function validateBody<T>(schema: ZodType<T>): RequestHandler {
  return (req: Request, _res: Response, next: NextFunction) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      next(HttpError.badRequest('Invalid request body', result.error.flatten()));
      return;
    }
    req.body = result.data;
    next();
  };
}
