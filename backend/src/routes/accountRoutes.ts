import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { requireAuth } from '../middleware/authMiddleware';
import { validateBody } from '../middleware/validate';
import { authRateLimiter } from '../middleware/rateLimiter';
import { deleteAccount } from '../services/accountDeletionService';
import { recordAuditEvent } from '../services/auditLogService';

export const accountRouter = Router();

// Deletes the signed-in civilian's account (see accountDeletionService for
// exactly what is removed and what is kept). The app has no screen for this
// yet; the confirmation string guards against accidental calls.
const deleteSchema = z.object({ confirm: z.literal('DELETE_MY_ACCOUNT') });

accountRouter.delete(
  '/',
  authRateLimiter,
  requireAuth,
  validateBody(deleteSchema),
  asyncHandler(async (req, res) => {
    const userId = req.authUser!.id;
    const result = await deleteAccount(userId);
    await recordAuditEvent({
      action: 'account.delete',
      resourceType: 'user',
      resourceId: userId,
      outcome: 'success',
      metadata: { ...result },
    });
    res.json({ deleted: true, ...result });
  }),
);
