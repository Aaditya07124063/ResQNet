import type { NextFunction, Request, Response } from 'express';
import { HttpError } from '../utils/httpError';
import { asyncHandler } from '../utils/asyncHandler';
import { verifyEmployeeAccessToken } from '../services/employeeAuthService';
import { getEmployeeById } from '../services/employeeService';
import type { AuthenticatedEmployee } from '../models/Employee';

declare module 'express-serve-static-core' {
  interface Request {
    /** Set by requireEmployeeAuth after verifying the employee-portal
     * access token. Deliberately a separate field from `authUser` —
     * a single request is never both a consumer user and an employee. */
    authEmployee?: AuthenticatedEmployee;
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
 * Verifies the employee-portal access token (mirrors authMiddleware.ts's
 * requireAuth exactly, scoped to the employee identity space) on every
 * request to a protected employee route, then loads the corresponding
 * employee and attaches it to the request.
 *
 * Never trust a client-supplied employee id for authorization — always
 * derive identity from req.authEmployee.id, set here from the verified
 * token only.
 */
export const requireEmployeeAuth = asyncHandler(async (req: Request, _res: Response, next: NextFunction) => {
  const token = extractBearerToken(req);
  const employeeId = verifyEmployeeAccessToken(token);

  const employee = await getEmployeeById(employeeId);
  if (!employee) {
    throw HttpError.unauthorized('Session refers to an employee that no longer exists');
  }
  if (employee.status === 'disabled') {
    throw HttpError.forbidden('This employee account is disabled');
  }

  req.authEmployee = employee;
  next();
});
