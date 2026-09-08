import { Router } from 'express';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { validateBody } from '../../middleware/validate';
import { upsertSettingSchema } from '../../validation/employeeSchemas';
import { getSetting, listSettings, upsertSetting } from '../../services/adminSettingsService';
import { recordAuditEvent } from '../../services/auditLogService';

export const employeeSettingsRouter = Router();

// SETTINGS_MANAGE is distinct from EMPLOYEE_MANAGE — an employee trusted
// to configure moderation thresholds etc. is not automatically trusted to
// create/manage other employee accounts, and vice versa (granular, not
// hardcoded, per employee_permissions' own design principle).
const SETTINGS_MANAGE = 'SETTINGS_MANAGE';

employeeSettingsRouter.get(
  '/',
  requireEmployeeAuth,
  requirePermission(SETTINGS_MANAGE),
  asyncHandler(async (_req, res) => {
    const settings = await listSettings();
    res.json({ settings });
  }),
);

employeeSettingsRouter.get(
  '/:key',
  requireEmployeeAuth,
  requirePermission(SETTINGS_MANAGE),
  asyncHandler(async (req, res) => {
    const setting = await getSetting(req.params.key!);
    if (!setting) throw HttpError.notFound('Setting not found');
    res.json({ setting });
  }),
);

employeeSettingsRouter.put(
  '/:key',
  requireEmployeeAuth,
  requirePermission(SETTINGS_MANAGE),
  validateBody(upsertSettingSchema),
  asyncHandler(async (req, res) => {
    const key = req.params.key!;
    const { value, description } = req.body as { value: unknown; description: string | null };
    const setting = await upsertSetting(key, value, description, req.authEmployee!.id);

    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'admin_settings.update',
      resourceType: 'admin_setting',
      resourceId: key,
      outcome: 'success',
      ipAddress: req.ip,
    });

    res.json({ setting });
  }),
);
