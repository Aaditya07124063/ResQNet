import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { validateBody } from '../middleware/validate';
import { requireSeismicWebhookAuth } from '../middleware/seismicWebhookAuth';
import { seismicCorroborationAlertSchema } from '../validation/seismicSchemas';
import { notifySeismicCorroboration } from '../services/pushNotificationService';

export const internalRouter = Router();

// LEGACY — no longer on the active path. Earthquake correlation now runs
// in this backend (POST /api/v1/seismic/reports → seismicService.ts), and
// the app no longer writes the Firestore `seismic_events` collection that
// functions/index.js's correlateSeismicEvent Cloud Function listened to,
// so that function (this route's only caller) receives nothing. Kept,
// secret-gated (seismicWebhookAuth.ts), until the Cloud Function is
// confirmed undeployed; then this route, its middleware, and functions/
// can be removed.
internalRouter.post(
  '/seismic-alerts',
  requireSeismicWebhookAuth,
  validateBody(seismicCorroborationAlertSchema),
  asyncHandler(async (req, res) => {
    await notifySeismicCorroboration(req.body);
    res.status(202).json({ ok: true });
  }),
);
