import { Router } from 'express';
import { asyncHandler } from '../../utils/asyncHandler';
import { validateBody } from '../../middleware/validate';
import { employeeAuthRateLimiter } from '../../middleware/rateLimiter';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { employeeLoginSchema } from '../../validation/employeeSchemas';
import { refreshSchema } from '../../validation/authSchemas';
import {
  loginEmployee,
  revokeEmployeeRefreshToken,
  rotateEmployeeRefreshToken,
  type IssuedEmployeeSession,
} from '../../services/employeeAuthService';
import { recordAuditEvent } from '../../services/auditLogService';
import { HttpError } from '../../utils/httpError';

export const employeeAuthRouter = Router();

function requestContext(req: import('express').Request) {
  return { userAgent: req.header('user-agent') ?? null, ipAddress: req.ip ?? null };
}

function sessionResponse(session: IssuedEmployeeSession) {
  return {
    accessToken: session.accessToken,
    accessTokenExpiresAt: session.accessTokenExpiresAt.toISOString(),
    refreshToken: session.refreshToken,
    refreshTokenExpiresAt: session.refreshTokenExpiresAt.toISOString(),
  };
}

// This is the employee portal's OWN login — separate from the consumer
// Google/phone sign-in flow (authRoutes.ts), matching the schema's
// password_hash column on `employees` and the "separate identity space"
// design principle stated throughout 001_init_schema.sql.
employeeAuthRouter.post(
  '/login',
  employeeAuthRateLimiter,
  validateBody(employeeLoginSchema),
  asyncHandler(async (req, res) => {
    const { email, password } = req.body as { email: string; password: string };
    const result = await loginEmployee(email, password, requestContext(req));

    if (!result) {
      // Invalid email, wrong password, and a disabled account all reach
      // here identically — never reveal which one it was.
      await recordAuditEvent({
        action: 'employee_auth.login',
        resourceType: 'employee_session',
        outcome: 'denied',
        ipAddress: req.ip,
        metadata: { email },
      });
      throw HttpError.unauthorized('Invalid email or password');
    }

    await recordAuditEvent({
      actorEmployeeId: result.employee.id,
      action: 'employee_auth.login',
      resourceType: 'employee_session',
      outcome: 'success',
      ipAddress: req.ip,
    });

    res.json({ employee: result.employee, session: sessionResponse(result.session) });
  }),
);

employeeAuthRouter.post(
  '/refresh',
  employeeAuthRateLimiter,
  validateBody(refreshSchema),
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body as { refreshToken: string };
    const session = await rotateEmployeeRefreshToken(refreshToken, requestContext(req));
    res.json({ session: sessionResponse(session) });
  }),
);

employeeAuthRouter.post(
  '/logout',
  requireEmployeeAuth,
  validateBody(refreshSchema),
  asyncHandler(async (req, res) => {
    const { refreshToken } = req.body as { refreshToken: string };
    await revokeEmployeeRefreshToken(refreshToken);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'employee_auth.logout',
      resourceType: 'employee_session',
      outcome: 'success',
      ipAddress: req.ip,
    });
    res.status(204).send();
  }),
);
