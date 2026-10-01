import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { listActiveAlerts } from '../services/alertService';
import { createAlertSigner } from '../utils/alertSignature';
import { env } from '../config/env';

export const alertRouter = Router();

// Built once at startup; a malformed key fails fast here rather than per request.
const signer = createAlertSigner(env.OFFICIAL_ALERT_SIGNING_KEY);

// Public: alerts currently in force, each labelled with its source. No
// personal data; available without an account so anyone can see them.
alertRouter.get(
  '/',
  asyncHandler(async (_req, res) => {
    const alerts = await listActiveAlerts();
    res.json({
      alerts: signer
        ? alerts.map((alert) => ({ ...alert, signature: signer.sign(alert), signingKeyId: signer.keyId }))
        : alerts,
    });
  }),
);
