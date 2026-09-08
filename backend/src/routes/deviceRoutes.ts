import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { HttpError } from '../utils/httpError';
import { requireAuth } from '../middleware/authMiddleware';
import { deviceRateLimiter } from '../middleware/rateLimiter';
import { validateBody } from '../middleware/validate';
import { registerDeviceSchema } from '../validation/deviceSchemas';
import { registerDeviceKeySchema } from '../validation/deviceKeySchemas';
import { deleteDevice, listDevices, registerDevice } from '../services/deviceService';
import { listDeviceKeys, registerDeviceKey, revokeDeviceKey } from '../services/deviceKeyService';

export const deviceRouter = Router();

const uuidParam = z.string().uuid();
function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// Every route here operates exclusively on req.authUser.id (the caller's
// own devices) — there is no route that takes a target user id from the
// client, matching the ownership-scoping convention used throughout
// (profileRoutes.ts, sosRoutes.ts). A device's owner is ALWAYS the
// authenticated session, never a client-supplied field.

deviceRouter.post(
  '/',
  requireAuth,
  deviceRateLimiter,
  validateBody(registerDeviceSchema),
  asyncHandler(async (req, res) => {
    const device = await registerDevice(req.authUser!.id, req.body);
    res.status(201).json({ device });
  }),
);

deviceRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const devices = await listDevices(req.authUser!.id);
    res.json({ devices });
  }),
);

deviceRouter.delete(
  '/:id',
  requireAuth,
  deviceRateLimiter,
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    await deleteDevice(req.authUser!.id, id);
    res.status(204).send();
  }),
);

// Cryptographic device-identity keys (origin authentication for
// mesh-relayed SOS events) — a distinct concept from the push-token rows
// above (see device_keys' own schema comment), but kept under the same
// `/devices` resource family since both describe "this authenticated
// user's own device". Registered automatically, post-login, whenever the
// app is online — the same pattern already used for push-token
// registration — so that by the time a device goes offline it normally
// already has a registered key (see docs on the offline/edge case).

deviceRouter.post(
  '/keys',
  requireAuth,
  deviceRateLimiter,
  validateBody(registerDeviceKeySchema),
  asyncHandler(async (req, res) => {
    const { deviceKey, reconciledEventCount } = await registerDeviceKey(req.authUser!.id, req.body);
    res.status(201).json({ deviceKey, reconciledEventCount });
  }),
);

deviceRouter.get(
  '/keys',
  requireAuth,
  asyncHandler(async (req, res) => {
    const deviceKeys = await listDeviceKeys(req.authUser!.id);
    res.json({ deviceKeys });
  }),
);

// Compromised/lost/stolen-device handling: revocable from ANY of the
// user's own authenticated sessions (not necessarily the device being
// revoked, which may be the one that was lost). Ownership-scoped by
// req.authUser.id, matching every other owned-resource delete in this
// codebase.
deviceRouter.delete(
  '/keys/:deviceId',
  requireAuth,
  deviceRateLimiter,
  asyncHandler(async (req, res) => {
    const deviceId = requireUuidParam(req.params.deviceId);
    await revokeDeviceKey(req.authUser!.id, deviceId);
    res.status(204).send();
  }),
);
