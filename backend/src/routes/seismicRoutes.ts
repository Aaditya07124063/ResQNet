import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { requireAuth } from '../middleware/authMiddleware';
import { validateBody } from '../middleware/validate';
import { seismicReportRateLimiter } from '../middleware/rateLimiter';
import { seismicReportSchema } from '../validation/seismicSchemas';
import { recordSeismicReport } from '../services/seismicService';

export const seismicRouter = Router();

// A signed-in device reports a local earthquake candidate; the response
// says whether nearby devices corroborate it. Identity comes from the
// ResQNet session only (never from the body).
seismicRouter.post(
  '/reports',
  requireAuth,
  seismicReportRateLimiter,
  validateBody(seismicReportSchema),
  asyncHandler(async (req, res) => {
    const result = await recordSeismicReport(req.authUser!.id, req.body);
    res.status(201).json({ result });
  }),
);
