import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { AUDIT_PAGE_MAX, listAuditLogs } from '../../services/auditLogQueryService';

export const AUDIT_LOG_VIEW = 'AUDIT_LOG_VIEW';

export const auditLogRouter = Router();

const querySchema = z.object({
  resourceType: z.string().trim().min(1).max(40).optional(),
  resourceId: z.string().trim().min(1).max(64).optional(),
  actionPrefix: z.string().trim().min(1).max(80).optional(),
  outcome: z.enum(['success', 'denied', 'error']).optional(),
  actorEmployeeId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(AUDIT_PAGE_MAX).optional(),
  before: z.string().regex(/^\d{1,18}$/).optional(),
});

auditLogRouter.get(
  '/',
  requireEmployeeAuth,
  requirePermission(AUDIT_LOG_VIEW),
  asyncHandler(async (req, res) => {
    const query = querySchema.safeParse(req.query);
    if (!query.success) throw HttpError.badRequest('Invalid audit log query', query.error.flatten());
    res.json(await listAuditLogs(query.data));
  }),
);
