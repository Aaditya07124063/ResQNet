import { Router, type Request } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { validateBody } from '../../middleware/validate';
import { hasPermission } from '../../services/employeePermissionService';
import { recordAuditEvent } from '../../services/auditLogService';
import { createAlert, getAlert, listAllAlerts, updateAlert } from '../../services/alertService';
import { getDisasterSourceStatus } from '../../services/disasterSources';
import { createAlertSchema, updateAlertSchema, type CreateAlertInput } from '../../validation/alertSchemas';

export const employeeAlertRouter = Router();

// One permission per source label, so being allowed to post ResQNet system
// notices never lets someone publish something labelled as an official
// government alert. SUPER_ADMIN holds all of them implicitly.
export const ALERT_PUBLISH_PERMISSION: Record<CreateAlertInput['sourceType'], string> = {
  official: 'OFFICIAL_ALERT_PUBLISH',
  verified_partner: 'PARTNER_ALERT_PUBLISH',
  resqnet_system: 'SYSTEM_ALERT_PUBLISH',
};

async function requirePublishPermission(req: Request, sourceType: string, action: string, alertId?: string) {
  const permission = ALERT_PUBLISH_PERMISSION[sourceType as CreateAlertInput['sourceType']];
  if (!permission || !(await hasPermission(req.authEmployee!, permission))) {
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action,
      resourceType: 'emergency_alert',
      resourceId: alertId ?? null,
      outcome: 'denied',
      ipAddress: req.ip,
      metadata: { sourceType },
    });
    throw HttpError.forbidden(`Missing required permission: ${permission ?? 'none for this source'}`);
  }
}

/** Reading alerts: any alert publisher, or SOS_MONITOR (situational awareness). Publishing is separate. */
export const ALERT_VIEW_PERMISSIONS = [...Object.values(ALERT_PUBLISH_PERMISSION), 'SOS_MONITOR'];

async function requireAlertViewer(req: Request) {
  const allowed = await Promise.all(ALERT_VIEW_PERMISSIONS.map((p) => hasPermission(req.authEmployee!, p)));
  if (!allowed.some(Boolean)) {
    throw HttpError.forbidden('Missing required permission: SOS_MONITOR or an alert publish permission');
  }
}

const uuidParam = z.string().uuid();
function alertId(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.notFound('Alert not found');
  return result.data;
}

employeeAlertRouter.use(requireEmployeeAuth);

employeeAlertRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    await requireAlertViewer(req);
    res.json({ alerts: await listAllAlerts() });
  }),
);

// Registered before '/:id'. Read-only: which external sources exist, and
// whether ingestion actually runs.
employeeAlertRouter.get(
  '/sources',
  asyncHandler(async (req, res) => {
    await requireAlertViewer(req);
    res.json({ sources: await getDisasterSourceStatus() });
  }),
);

employeeAlertRouter.post(
  '/',
  validateBody(createAlertSchema),
  asyncHandler(async (req, res) => {
    const input = req.body as CreateAlertInput;
    await requirePublishPermission(req, input.sourceType, 'emergency_alert.create');
    const alert = await createAlert(req.authEmployee!.id, input);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'emergency_alert.create',
      resourceType: 'emergency_alert',
      resourceId: alert.id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { sourceType: alert.sourceType, sourceName: alert.sourceName, severity: alert.severity },
    });
    res.status(201).json({ alert });
  }),
);

employeeAlertRouter.patch(
  '/:id',
  validateBody(updateAlertSchema),
  asyncHandler(async (req, res) => {
    const id = alertId(req.params.id);
    const existing = await getAlert(id);
    await requirePublishPermission(req, existing.sourceType, 'emergency_alert.update', id);
    const alert = await updateAlert(id, req.body);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'emergency_alert.update',
      resourceType: 'emergency_alert',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { changed: Object.keys(req.body), status: alert.status },
    });
    res.json({ alert });
  }),
);
