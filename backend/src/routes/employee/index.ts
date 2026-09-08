import { Router } from 'express';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { employeeAuthRouter } from './authRoutes';
import { employeeManagementRouter } from './employeeManagementRoutes';
import { employeeSettingsRouter } from './settingsRoutes';
import { moderationRouter } from './moderationRoutes';
import { listPermissions } from '../../services/employeePermissionService';
import { asyncHandler } from '../../utils/asyncHandler';

export const employeeRouter = Router();

employeeRouter.use('/auth', employeeAuthRouter);
employeeRouter.use('/employees', employeeManagementRouter);
employeeRouter.use('/settings', employeeSettingsRouter);
employeeRouter.use('/review-cases', moderationRouter);

// Identity-check endpoint, mirroring GET /api/v1/me for consumer users —
// returns the authenticated employee plus their own granted permissions
// (an empty list for a SUPER_ADMIN, whose bypass is implicit and doesn't
// need rows — the client already knows that role means "all permissions",
// matching employee_permissions' own doc comment).
employeeRouter.get(
  '/me',
  requireEmployeeAuth,
  asyncHandler(async (req, res) => {
    const permissions = await listPermissions(req.authEmployee!.id);
    res.json({ employee: req.authEmployee, permissions });
  }),
);
