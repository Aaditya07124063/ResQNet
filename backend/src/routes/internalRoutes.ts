import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { validateBody } from '../middleware/validate';
import { requireSeismicWebhookAuth } from '../middleware/seismicWebhookAuth';
import { seismicCorroborationAlertSchema } from '../validation/seismicSchemas';
import { notifySeismicCorroboration } from '../services/pushNotificationService';

export const internalRouter = Router();

// Service-to-service only — never called by the Flutter app or any
// authenticated user/employee session. The caller is
// functions/index.js's correlateSeismicEvent Cloud Function, which has
// no ResQNet identity of its own, hence the shared-secret gate
// (seismicWebhookAuth.ts) instead of requireAuth/requireEmployeeAuth.
internalRouter.post(
  '/seismic-alerts',
  requireSeismicWebhookAuth,
  validateBody(seismicCorroborationAlertSchema),
  asyncHandler(async (req, res) => {
    await notifySeismicCorroboration(req.body);
    res.status(202).json({ ok: true });
  }),
);
