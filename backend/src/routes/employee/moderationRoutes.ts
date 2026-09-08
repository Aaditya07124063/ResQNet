import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../../utils/asyncHandler';
import { HttpError } from '../../utils/httpError';
import { requireEmployeeAuth } from '../../middleware/employeeAuthMiddleware';
import { requirePermission } from '../../middleware/rbac';
import { validateBody } from '../../middleware/validate';
import { takeModerationActionSchema } from '../../validation/moderationSchemas';
import { getReviewCaseWithReports, listReviewCases, takeModerationAction } from '../../services/moderationService';

export const moderationRouter = Router();

const uuidParam = z.string().uuid();
function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

const statusQuerySchema = z.enum(['open', 'closed']).optional();

// Permission names reuse the exact vocabulary the employee_permissions
// table's own doc comment proposed ("USER_VIEW, USER_SUSPEND,
// MESSAGE_REVIEW, ...") rather than inventing new ones. USER_SUSPEND
// gates every moderation-action type here (not just literal suspension —
// the schema doesn't suggest a separate permission per action_type, and
// MESSAGE_REVIEW is reserved for the (deferred, no data exists yet)
// last-100-messages capability specifically.

moderationRouter.get(
  '/',
  requireEmployeeAuth,
  requirePermission('USER_VIEW'),
  asyncHandler(async (req, res) => {
    const parsedStatus = statusQuerySchema.safeParse(req.query.status);
    if (!parsedStatus.success) throw HttpError.badRequest('Invalid status filter');
    const reviewCases = await listReviewCases(parsedStatus.data);
    res.json({ reviewCases });
  }),
);

moderationRouter.get(
  '/:id',
  requireEmployeeAuth,
  requirePermission('USER_VIEW'),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const result = await getReviewCaseWithReports(id);
    if (!result) throw HttpError.notFound('Review case not found');
    res.json({ reviewCase: result.reviewCase, reports: result.reports });
  }),
);

moderationRouter.post(
  '/:id/actions',
  requireEmployeeAuth,
  requirePermission('USER_SUSPEND'),
  validateBody(takeModerationActionSchema),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    // Identity is always the authenticated session's employee id — a
    // client-supplied performedByEmployeeId in the body was already
    // stripped by validateBody (not part of takeModerationActionSchema).
    const result = await takeModerationAction(id, req.authEmployee!.id, req.body);
    res.status(201).json({ action: result.action, reviewCase: result.reviewCase });
  }),
);
