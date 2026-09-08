import { Client as MinioClient } from 'minio';
import { env } from '../config/env';
import { logger } from '../utils/logger';
import { contentTypeFor, type DetectedImageType, extensionFor } from '../utils/imageSignature';

const BUCKET_REGION = 'us-east-1';
/** 5-15 minute window, per Phase 6 spec — short enough that a leaked URL
 * (e.g. in a proxy log somewhere outside our control) has a small blast
 * radius, long enough that a client fetching an image doesn't race it. */
const SIGNED_URL_EXPIRY_SECONDS = 10 * 60;

let client: MinioClient | undefined;

function getClient(): MinioClient {
  if (!client) {
    client = new MinioClient({
      endPoint: env.MINIO_ENDPOINT,
      port: env.MINIO_PORT,
      useSSL: env.MINIO_USE_SSL,
      accessKey: env.MINIO_ACCESS_KEY,
      secretKey: env.MINIO_SECRET_KEY,
    });
  }
  return client;
}

// Idempotent, memoized so repeated calls (one per request, in the simplest
// wiring) don't re-check the bucket over the network every time — the
// underlying check/create only ever actually runs once per process.
let bucketReadyPromise: Promise<void> | undefined;

function ensureBucketExists(): Promise<void> {
  if (!bucketReadyPromise) {
    bucketReadyPromise = (async () => {
      const minio = getClient();
      const exists = await minio.bucketExists(env.MINIO_PROFILE_IMAGES_BUCKET);
      if (!exists) {
        await minio.makeBucket(env.MINIO_PROFILE_IMAGES_BUCKET, BUCKET_REGION);
        logger.info({ bucket: env.MINIO_PROFILE_IMAGES_BUCKET }, 'Created MinIO bucket');
      }
    })().catch((err) => {
      // Let the next call retry instead of caching a failed init forever.
      bucketReadyPromise = undefined;
      throw err;
    });
  }
  return bucketReadyPromise;
}

/**
 * The object key is derived ONLY from the verified backend user id
 * (never a Google subject, Firebase uid, or anything client-supplied) and
 * the verified file type (never a client-declared extension) — see
 * backend/src/utils/imageSignature.ts. One object per user; a re-upload
 * overwrites the previous object at the same key.
 */
export function profileImageObjectKey(userId: string, type: DetectedImageType): string {
  return `profile-images/${userId}.${extensionFor(type)}`;
}

export async function uploadProfileImage(
  userId: string,
  buffer: Buffer,
  type: DetectedImageType,
): Promise<string> {
  await ensureBucketExists();
  const objectKey = profileImageObjectKey(userId, type);
  await getClient().putObject(env.MINIO_PROFILE_IMAGES_BUCKET, objectKey, buffer, buffer.length, {
    'Content-Type': contentTypeFor(type),
  });
  return objectKey;
}

/** Only ever call this AFTER an authorization check has already passed —
 * this function itself does no authorization, it just mints a URL. */
export async function getSignedProfileImageUrl(objectKey: string): Promise<string> {
  await ensureBucketExists();
  return getClient().presignedGetObject(
    env.MINIO_PROFILE_IMAGES_BUCKET,
    objectKey,
    SIGNED_URL_EXPIRY_SECONDS,
  );
}

export async function deleteProfileImage(objectKey: string): Promise<void> {
  await ensureBucketExists();
  await getClient().removeObject(env.MINIO_PROFILE_IMAGES_BUCKET, objectKey);
}
