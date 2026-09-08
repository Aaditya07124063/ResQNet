import { Router } from 'express';
import { asyncHandler } from '../utils/asyncHandler';
import { requireAuth } from '../middleware/authMiddleware';
import { nearbyAlertRateLimiter } from '../middleware/rateLimiter';
import { validateBody } from '../middleware/validate';
import { updateNearbyLocationSchema, updateNearbyPreferenceSchema } from '../validation/nearbyAlertSchemas';
import { getNearbyPreference, setNearbyPreference, upsertNearbyLocationIfEnabled } from '../services/nearbyAlertService';

export const nearbyAlertRouter = Router();

// Every route here operates exclusively on req.authUser.id — a user can
// only ever read or change their OWN nearby-alert preference/location,
// matching the ownership-scoping convention used throughout.

nearbyAlertRouter.get(
  '/preference',
  requireAuth,
  asyncHandler(async (req, res) => {
    const preference = await getNearbyPreference(req.authUser!.id);
    res.json({ preference });
  }),
);

nearbyAlertRouter.put(
  '/preference',
  requireAuth,
  nearbyAlertRateLimiter,
  validateBody(updateNearbyPreferenceSchema),
  asyncHandler(async (req, res) => {
    const preference = await setNearbyPreference(req.authUser!.id, req.body);
    res.json({ preference });
  }),
);

nearbyAlertRouter.put(
  '/location',
  requireAuth,
  nearbyAlertRateLimiter,
  validateBody(updateNearbyLocationSchema),
  asyncHandler(async (req, res) => {
    const stored = await upsertNearbyLocationIfEnabled(req.authUser!.id, req.body.latitude, req.body.longitude);
    res.json({ stored });
  }),
);
