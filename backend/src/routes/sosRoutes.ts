import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { HttpError } from '../utils/httpError';
import { requireAuth } from '../middleware/authMiddleware';
import { sosRateLimiter, nearbyAlertRateLimiter } from '../middleware/rateLimiter';
import { validateBody } from '../middleware/validate';
import { createSosEventSchema, updateSosEventStatusSchema } from '../validation/sosSchemas';
import { createSosEvent, getNearbyEmergencyDetail, listSosEvents, updateSosEventStatus } from '../services/sosService';

export const sosRouter = Router();

const uuidParam = z.string().uuid();

function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// Every route here operates exclusively on req.authUser.id (the caller's
// own SOS events) — there is no route that takes a target user id from
// the client, matching the ownership-scoping convention used throughout
// (profileRoutes.ts, trustedContactsService.ts).

sosRouter.post(
  '/',
  requireAuth,
  sosRateLimiter,
  validateBody(createSosEventSchema),
  asyncHandler(async (req, res) => {
    const event = await createSosEvent(req.authUser!.id, req.body);
    res.status(201).json({ event });
  }),
);

sosRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const events = await listSosEvents(req.authUser!.id);
    res.json({ events });
  }),
);

sosRouter.patch(
  '/:id',
  requireAuth,
  validateBody(updateSosEventStatusSchema),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const event = await updateSosEventStatus(req.authUser!.id, id, req.body);
    res.json({ event });
  }),
);

// Section 12/14: a nearby (non-trusted-contact) recipient's authorized
// view of an emergency they were alerted about — deliberately NOT the
// full sos_events row (no reporter identity, message, or exact
// coordinates). Authorization is a real sos_recipients row for this
// caller, not just "the event exists" — see getNearbyEmergencyDetail.
sosRouter.get(
  '/:id/nearby-detail',
  requireAuth,
  nearbyAlertRateLimiter,
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const detail = await getNearbyEmergencyDetail(req.authUser!.id, id);
    res.json({ detail });
  }),
);
