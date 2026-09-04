import { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { HttpError } from '../utils/httpError';
import { requireAuth } from '../middleware/authMiddleware';
import { validateBody } from '../middleware/validate';
import { profileUpdateSchema, trustedContactSchema } from '../validation/profileSchemas';
import { getProfile, upsertProfile } from '../services/profileService';
import {
  createTrustedContact,
  deleteTrustedContact,
  listTrustedContacts,
  updateTrustedContact,
} from '../services/trustedContactsService';

export const profileRouter = Router();

const uuidParam = z.string().uuid();

function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

// All routes here operate exclusively on req.authUser.id (the caller's own
// profile / own trusted contacts) — there is no route that takes a target
// user id from the client, by design (see docs/AUDIT.md §7: a user may
// access only their own profile and their own trusted contacts).

profileRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const profile = await getProfile(req.authUser!.id);
    res.json({ profile });
  }),
);

profileRouter.put(
  '/',
  requireAuth,
  validateBody(profileUpdateSchema),
  asyncHandler(async (req, res) => {
    const profile = await upsertProfile(req.authUser!.id, req.body);
    res.json({ profile });
  }),
);

profileRouter.get(
  '/trusted-contacts',
  requireAuth,
  asyncHandler(async (req, res) => {
    const contacts = await listTrustedContacts(req.authUser!.id);
    res.json({ contacts });
  }),
);

profileRouter.post(
  '/trusted-contacts',
  requireAuth,
  validateBody(trustedContactSchema),
  asyncHandler(async (req, res) => {
    const contact = await createTrustedContact(req.authUser!.id, req.body);
    res.status(201).json({ contact });
  }),
);

profileRouter.put(
  '/trusted-contacts/:id',
  requireAuth,
  validateBody(trustedContactSchema),
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    const contact = await updateTrustedContact(req.authUser!.id, id, req.body);
    res.json({ contact });
  }),
);

profileRouter.delete(
  '/trusted-contacts/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const id = requireUuidParam(req.params.id);
    await deleteTrustedContact(req.authUser!.id, id);
    res.status(204).send();
  }),
);
