import express, { Router } from 'express';
import { z } from 'zod';
import { asyncHandler } from '../utils/asyncHandler';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { requireAuth } from '../middleware/authMiddleware';
import { detectImageType } from '../utils/imageSignature';
import {
  deleteProfileImage,
  getSignedProfileImageUrl,
  uploadProfileImage,
} from '../services/storageService';
import { clearProfileImageKey, getProfile, setProfileImageKey } from '../services/profileService';
import { canViewProfileImage } from '../services/profileImageAccessService';

export const profileImageRouter = Router();

const MAX_UPLOAD_BYTES = 5 * 1024 * 1024; // matches the prior Firebase Storage rule's limit

const uuidParam = z.string().uuid();

function requireUuidParam(value: string | undefined): string {
  const result = uuidParam.safeParse(value);
  if (!result.success) throw HttpError.badRequest('Invalid id');
  return result.data;
}

/**
 * Runs a storageService call and converts ANY failure into a generic,
 * safe HttpError — regardless of NODE_ENV. Deliberately not left to the
 * shared errorHandler's prod-only message redaction: a MinIO connection
 * string, bucket name, or internal error detail must never reach a
 * client even in dev/test, so it's normalized here at the source instead.
 */
async function runStorageOp<T>(op: () => Promise<T>, context: string): Promise<T> {
  try {
    return await op();
  } catch (err) {
    logger.error({ err, context }, 'Profile image storage operation failed');
    throw HttpError.internal('Image storage is temporarily unavailable');
  }
}

// Raw binary body, scoped to this router only — the app-wide express.json()
// parser in app.ts is untouched and still handles every JSON route. Any
// Content-Type other than image/* is left unparsed (req.body stays
// undefined), which the handler below treats as "missing image".
const rawImageBody = express.raw({ type: 'image/*', limit: MAX_UPLOAD_BYTES });

/**
 * Uploads/replaces the caller's own profile picture. Never accepts a
 * client-supplied user id or object key — the object key is derived
 * entirely server-side from req.authUser.id (see storageService.ts).
 */
profileImageRouter.put(
  '/image',
  requireAuth,
  rawImageBody,
  asyncHandler(async (req, res) => {
    const buffer = req.body as Buffer | undefined;
    if (!buffer || !Buffer.isBuffer(buffer) || buffer.length === 0) {
      throw HttpError.badRequest('Missing image body (send raw bytes with an image/* Content-Type)');
    }

    // The real format, from the actual bytes — never trust the
    // declared Content-Type or any client-supplied extension/filename.
    const detectedType = detectImageType(buffer);
    if (!detectedType) {
      throw HttpError.badRequest('Unsupported or invalid image format');
    }

    const objectKey = await runStorageOp(
      () => uploadProfileImage(req.authUser!.id, buffer, detectedType),
      'uploadProfileImage',
    );
    await setProfileImageKey(req.authUser!.id, objectKey);
    res.status(200).json({ ok: true });
  }),
);

/** Deletes the caller's own profile picture, if one exists. */
profileImageRouter.delete(
  '/image',
  requireAuth,
  asyncHandler(async (req, res) => {
    const profile = await getProfile(req.authUser!.id);
    if (profile?.profileImageObjectKey) {
      await runStorageOp(() => deleteProfileImage(profile.profileImageObjectKey!), 'deleteProfileImage');
      await clearProfileImageKey(req.authUser!.id);
    }
    res.status(204).send();
  }),
);

/** Owner fetching their own picture — always allowed regardless of the
 * configured visibility (visibility only governs OTHER viewers). */
profileImageRouter.get(
  '/image',
  requireAuth,
  asyncHandler(async (req, res) => {
    const profile = await getProfile(req.authUser!.id);
    if (!profile?.profileImageObjectKey) {
      throw HttpError.notFound('No profile picture set');
    }
    const url = await runStorageOp(
      () => getSignedProfileImageUrl(profile.profileImageObjectKey!),
      'getSignedProfileImageUrl',
    );
    res.json({ url, expiresInSeconds: 600 });
  }),
);

/**
 * Fetching another user's picture. The target user id is a legitimate
 * input here (unlike write routes, which never take one) — but it only
 * ever selects WHOSE image is being requested. Whether the request is
 * actually allowed is decided entirely server-side by
 * canViewProfileImage(), never by anything the client claims.
 */
profileImageRouter.get(
  '/:userId/image',
  requireAuth,
  asyncHandler(async (req, res) => {
    const ownerId = requireUuidParam(req.params.userId);
    const profile = await getProfile(ownerId);
    if (!profile?.profileImageObjectKey) {
      throw HttpError.notFound('No profile picture set');
    }

    const allowed = await canViewProfileImage(
      req.authUser!.id,
      ownerId,
      profile.profilePictureVisibility,
    );
    if (!allowed) {
      // 404, not 403 — consistent with the rest of this backend's
      // ownership checks: never confirm a private resource exists.
      throw HttpError.notFound('No profile picture set');
    }

    const url = await runStorageOp(
      () => getSignedProfileImageUrl(profile.profileImageObjectKey!),
      'getSignedProfileImageUrl',
    );
    res.json({ url, expiresInSeconds: 600 });
  }),
);
