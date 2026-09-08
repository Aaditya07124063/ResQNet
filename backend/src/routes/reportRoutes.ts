import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { requireAuth } from '../middleware/authMiddleware';
import { reportRateLimiter } from '../middleware/rateLimiter';
import { validateBody } from '../middleware/validate';
import { createReportSchema } from '../validation/reportSchemas';
import { createReport } from '../services/reportService';

export const reportRouter = Router();

// POST /reports (top-level resource, alongside /auth and /profile) rather
// than nesting under a user id (e.g. /users/:id/reports) — there is no
// general-purpose /users collection route in this backend, and the
// authenticated reporter is always derived from the session, never from
// the URL, so a flat collection route is the better fit here.
//
// No GET route is added in this phase — reading back one's own submitted
// reports, or anything about review_cases, was not part of Phase 14's
// scope and risks exposing moderation-internal state (e.g. whether a
// report contributed to a threshold being crossed) to the very users
// being reported on. That's left for a deliberate future decision, not
// assumed here.
reportRouter.post(
  '/',
  requireAuth,
  reportRateLimiter,
  validateBody(createReportSchema),
  asyncHandler(async (req, res) => {
    const report = await createReport(req.authUser!.id, req.body);
    res.status(201).json({ report });
  }),
);
