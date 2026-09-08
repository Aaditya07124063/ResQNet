import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { validateBody } from '../../middleware/validate';
import { createEmployeeSchema, grantPermissionSchema } from '../../validation/employeeSchemas';
import { createEmployee, listEmployees } from '../../services/employeeService';
import { hashEmployeePassword } from '../../services/employeeAuthService';
import { grantPermission, listPermissions, revokePermission } from '../../services/employeePermissionService';
import { recordAuditEvent } from '../../services/auditLogService';

export const employeeManagementRouter = Router();

const uuidParam = z.string().uuid();
function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// EMPLOYEE_MANAGE gates the employee-portal's OWN administration
// (creating staff accounts, granting/revoking their permissions) — this
// is the bootstrap mechanism the employee_permissions table needs to be
// populated through at all (there is no other API for it), not a
// moderation/responder capability. SUPER_ADMIN has it implicitly via the
// role bypass in employeePermissionService.hasPermission(); it can also
// be granted to an ADMIN, matching the "granular, not hardcoded" design.
const EMPLOYEE_MANAGE = 'EMPLOYEE_MANAGE';

employeeManagementRouter.get(
  '/',
  requireEmployeeAuth,
  requirePermission(EMPLOYEE_MANAGE),
  asyncHandler(async (_req, res) => {
    const employees = await listEmployees();
    res.json({ employees });
  }),
);

employeeManagementRouter.post(
  '/',
  requireEmployeeAuth,
  requirePermission(EMPLOYEE_MANAGE),
  validateBody(createEmployeeSchema),
  asyncHandler(async (req, res) => {
    const { email, password, displayName, role } = req.body as {
      email: string;
      password: string;
      displayName: string;
      role: 'super_admin' | 'admin' | 'employee';
    };
    const passwordHash = await hashEmployeePassword(password);

    let employee;
    try {
      employee = await createEmployee({ email, passwordHash, displayName, role });
    } catch (err) {
      const code = typeof err === 'object' && err !== null ? (err as { code?: string }).code : undefined;
      if (code === '23505') {
        throw HttpError.conflict('An employee with this email already exists');
      }
      throw err;
    }

    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'employee.create',
      resourceType: 'employee',
      resourceId: employee.id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { role },
    });

    res.status(201).json({ employee });
  }),
);

employeeManagementRouter.get(
  '/:id/permissions',
  requireEmployeeAuth,
  requirePermission(EMPLOYEE_MANAGE),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const permissions = await listPermissions(id);
    res.json({ permissions });
  }),
);

employeeManagementRouter.post(
  '/:id/permissions',
  requireEmployeeAuth,
  requirePermission(EMPLOYEE_MANAGE),
  validateBody(grantPermissionSchema),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const { permission } = req.body as { permission: string };
    await grantPermission(id, permission, req.authEmployee!.id);

    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'employee.permission_granted',
      resourceType: 'employee',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { permission },
    });

    const permissions = await listPermissions(id);
    res.status(201).json({ permissions });
  }),
);

employeeManagementRouter.delete(
  '/:id/permissions/:permission',
  requireEmployeeAuth,
  requirePermission(EMPLOYEE_MANAGE),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const permission = req.params.permission!;
    await revokePermission(id, permission);

    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'employee.permission_revoked',
      resourceType: 'employee',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { permission },
    });

    res.status(204).send();
  }),
);
