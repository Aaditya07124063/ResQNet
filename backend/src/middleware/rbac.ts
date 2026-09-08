import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { HttpError } from '../utils/httpError';
import { hasPermission } from '../services/employeePermissionService';

/**
 * Permission-check middleware — must run AFTER requireEmployeeAuth (reads
 * req.authEmployee, throws a 500-shaped error via the non-null assertion
 * failing loudly if misordered, rather than silently allowing an
 * unauthenticated request through). SUPER_ADMIN bypasses every check;
 * everyone else needs an explicit employee_permissions row for exactly
 * this `permission` string — never inferred from role name alone.
 */
export function requirePermission(permission: string): RequestHandler {
  return (req: Request, _res: Response, next: NextFunction) => {
    if (!req.authEmployee) {
      next(HttpError.unauthorized('Authentication required'));
      return;
    }
    hasPermission(req.authEmployee, permission)
      .then((allowed) => {
        if (!allowed) {
          next(HttpError.forbidden(`Missing required permission: ${permission}`));
          return;
        }
        next();
      })
      .catch(next);
  };
}
