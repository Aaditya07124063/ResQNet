import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { validateBody } from '../../middleware/validate';
import { hasPermission } from '../../services/employeePermissionService';
import { recordAuditEvent } from '../../services/auditLogService';
import {
  getIncident,
  getIncidentCounts,
  listEligibleResponders,
  listIncidents,
  QUEUE_PAGE_MAX,
  recordIncidentUpdate,
  setRetentionHold,
  type QueueScope,
} from '../../services/incidentService';
import { RESPONDER_STATES } from '../../services/incidentStateMachine';

export const incidentRouter = Router();

// Permissions:
// - SOS_MONITOR: the queue, dashboard counts, and incident detail with an
//   approximate location and without the phone number, SOS message or note
//   text.
// - SOS_RESPOND: record progress and notes; with SOS_MONITOR also sees those
//   sensitive details. Every detail view is audit-logged.
// - SOS_ASSIGN (with SOS_RESPOND): assign, reassign, stand down, and record
//   progress on behalf of the assignee.
// super_admin holds every permission (employeePermissionService).
//
// Audit metadata never includes note text (it may describe injuries),
// tokens, or contact details.

const updateSchema = z.object({
  action: z.enum(['acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'resolved', 'stood_down', 'note']),
  note: z.string().trim().min(1).max(1000).optional(),
  assignedEmployeeId: z.string().uuid().optional(),
});

const queueQuerySchema = z.object({
  // `include=closed` is the earlier spelling of scope=all.
  scope: z.enum(['active', 'closed', 'all']).optional(),
  include: z.literal('closed').optional(),
  limit: z.coerce.number().int().min(1).max(QUEUE_PAGE_MAX).optional(),
  cursor: z.string().max(200).optional(),
  opsStatus: z.enum(RESPONDER_STATES).optional(),
  civilianState: z.enum(['active', 'safe', 'cancelled']).optional(),
  assignee: z.union([z.literal('unassigned'), z.string().uuid()]).optional(),
});

const uuidParam = z.string().uuid();
function incidentId(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.notFound('Incident not found');
  return result.data;
}

incidentRouter.use(requireEmployeeAuth);

incidentRouter.get(
  '/',
  requirePermission('SOS_MONITOR'),
  asyncHandler(async (req, res) => {
    const query = queueQuerySchema.safeParse(req.query);
    if (!query.success) throw HttpError.badRequest('Invalid queue query', query.error.flatten());
    const { include, scope: requested, ...rest } = query.data;
    const scope: QueueScope = requested ?? (include === 'closed' ? 'all' : 'active');
    res.json(await listIncidents({ scope, ...rest }));
  }),
);

// Registered before '/:id' so these paths are never read as incident ids.
incidentRouter.get(
  '/summary',
  requirePermission('SOS_MONITOR'),
  asyncHandler(async (_req, res) => {
    res.json({ counts: await getIncidentCounts() });
  }),
);

incidentRouter.get(
  '/responders',
  requirePermission('SOS_ASSIGN'),
  asyncHandler(async (_req, res) => {
    res.json({ responders: await listEligibleResponders() });
  }),
);

incidentRouter.get(
  '/:id',
  requirePermission('SOS_MONITOR'),
  asyncHandler(async (req, res) => {
    const id = incidentId(req.params.id);
    const includeSensitive = await hasPermission(req.authEmployee!, 'SOS_RESPOND');
    const incident = await getIncident(id, { includeSensitive });
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: 'incident.view',
      resourceType: 'sos_event',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { actorRole: req.authEmployee!.role, sensitiveDetailsIncluded: includeSensitive },
    });
    res.json({ incident });
  }),
);

incidentRouter.post(
  '/:id/updates',
  requirePermission('SOS_RESPOND'),
  validateBody(updateSchema),
  asyncHandler(async (req, res) => {
    const id = incidentId(req.params.id);
    const body = req.body as z.infer<typeof updateSchema>;
    const employee = req.authEmployee!;
    const canAssign = await hasPermission(employee, 'SOS_ASSIGN');
    const audit = (outcome: 'success' | 'denied', metadata: Record<string, unknown>) =>
      recordAuditEvent({
        actorEmployeeId: employee.id,
        action: `incident.${body.action}`,
        resourceType: 'sos_event',
        resourceId: id,
        outcome,
        ipAddress: req.ip,
        metadata: { actorRole: employee.role, ...metadata },
      });

    try {
      const result = await recordIncidentUpdate({ id: employee.id, role: employee.role, canAssign }, id, body);
      await audit('success', {
        previousState: result.previousState,
        newState: result.newState,
        civilianState: result.civilianState,
        assignedEmployeeId: body.action === 'assigned' ? body.assignedEmployeeId : undefined,
        hasNote: body.note !== undefined,
      });
      res.status(201).json({ opsStatus: result.newState, previousState: result.previousState });
    } catch (err) {
      // Authorization refusals and rejected transitions are part of the trail.
      if (err instanceof HttpError && (err.status === 403 || err.code === 'INVALID_TRANSITION')) {
        await audit('denied', { reason: err.code, requestedState: body.action });
      }
      throw err;
    }
  }),
);

// Retention hold (RETENTION_HOLD_MANAGE): pauses redaction and
// de-identification of one incident. Operational, not a legal
// determination. The reason is stored on the incident, not in the audit log.
export const RETENTION_HOLD_MANAGE = 'RETENTION_HOLD_MANAGE';
const holdSchema = z.discriminatedUnion('hold', [
  z.object({ hold: z.literal(true), reason: z.string().trim().min(3).max(500) }),
  z.object({ hold: z.literal(false) }),
]);

incidentRouter.post(
  '/:id/retention-hold',
  requirePermission(RETENTION_HOLD_MANAGE),
  validateBody(holdSchema),
  asyncHandler(async (req, res) => {
    const id = incidentId(req.params.id);
    const body = req.body as z.infer<typeof holdSchema>;
    const result = await setRetentionHold(req.authEmployee!.id, id, body);
    await recordAuditEvent({
      actorEmployeeId: req.authEmployee!.id,
      action: body.hold ? 'incident.retention_hold' : 'incident.retention_release',
      resourceType: 'sos_event',
      resourceId: id,
      outcome: 'success',
      ipAddress: req.ip,
      metadata: { actorRole: req.authEmployee!.role, sensitiveAlreadyRedacted: result.sensitiveAlreadyRedacted },
    });
    res.json({ retentionHold: result.held, sensitiveAlreadyRedacted: result.sensitiveAlreadyRedacted });
  }),
);
