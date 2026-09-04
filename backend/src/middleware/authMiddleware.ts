import type { NextFunction, Request, Response } from 'express';
import { HttpError } from '../utils/httpError';
import { asyncHandler } from '../utils/asyncHandler';
import { verifyAccessToken } from '../services/sessionService';
import { getUserById } from '../services/userService';
import type { AuthenticatedUser } from '../models/User';

declare module 'express-serve-static-core' {
  interface Request {
    /** Set by requireAuth after verifying the ResQNet access token. */
    authUser?: AuthenticatedUser;
  }
}

function extractBearerToken(req: Request): string {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    throw HttpError.unauthorized('Missing or malformed Authorization header');
  }
  const token = header.slice('Bearer '.length).trim();
  if (!token) {
    throw HttpError.unauthorized('Missing bearer token');
  }
  return token;
}

/**
 * Verifies the ResQNet access token (issued by sessionService after Google
 * ID token / phone OTP verification) on every request to a protected
 * route, then loads the corresponding user and attaches it to the request.
 *
 * Never trust a client-supplied user id for authorization — always derive
 * identity from req.authUser.id, set here from the verified token only.
 */
export const requireAuth = asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
  const token = extractBearerToken(req);
  const userId = verifyAccessToken(token);

  const user = await getUserById(userId);
  if (!user) {
    throw HttpError.unauthorized('Session refers to a user that no longer exists');
  }
  if (user.accountStatus === 'suspended' || user.accountStatus === 'deleted') {
    throw HttpError.forbidden('This account is not active');
  }

  req.authUser = user;
  next();
});
