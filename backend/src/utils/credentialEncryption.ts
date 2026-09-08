import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { env } from '../config/env';

// AES-256-GCM encryption for email_providers/sms_providers.encrypted_credentials
// (§U/§V of docs/AUDIT.md, .env.example's own PROVIDER_CREDENTIALS_ENCRYPTION_KEY
// comment). The key lives ONLY in backend environment config, never in this
// database or in source — see env.ts.
//
// Wire format (all in one BYTEA column): [12-byte IV][16-byte auth tag][ciphertext].
// GCM's auth tag gives authenticated encryption for free — decrypt() fails
// closed (throws) on any tampering rather than silently returning garbage
// plaintext. Node's own GCM tag check is already constant-time (done
// inside OpenSSL, not a JS comparison) — see decryptCredentials()'s own
// comment; no separate timingSafeEqual is needed or applicable here. (The
// codebase's actual secret-comparison need — the OTP code check — lives in
// verificationService.ts, which does use timingSafeEqual on the two SHA-256
// digests being compared.)

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH_BYTES = 12;
const AUTH_TAG_LENGTH_BYTES = 16;
const KEY_LENGTH_BYTES = 32;

class MissingEncryptionKeyError extends Error {
  constructor() {
    super('PROVIDER_CREDENTIALS_ENCRYPTION_KEY is not configured');
    this.name = 'MissingEncryptionKeyError';
  }
}

function loadKey(): Buffer {
  const configured = env.PROVIDER_CREDENTIALS_ENCRYPTION_KEY;
  if (!configured) {
    // Fail safely: never fall back to a hardcoded/derived/zero key. Any
    // caller (smsService.ts, a future email-provider dispatch, or an admin
    // credential-write path) must fail the individual request rather than
    // silently operating with weakened or absent encryption.
    throw new MissingEncryptionKeyError();
  }
  let key: Buffer;
  try {
    key = Buffer.from(configured, 'base64');
  } catch {
    throw new Error('PROVIDER_CREDENTIALS_ENCRYPTION_KEY is not valid base64');
  }
  if (key.length !== KEY_LENGTH_BYTES) {
    throw new Error(
      `PROVIDER_CREDENTIALS_ENCRYPTION_KEY must decode to exactly ${KEY_LENGTH_BYTES} bytes (got ${key.length})`,
    );
  }
  return key;
}

/**
 * Encrypts a JSON-serializable credentials object into the BYTEA blob
 * shape stored in email_providers/sms_providers.encrypted_credentials.
 * Throws MissingEncryptionKeyError if PROVIDER_CREDENTIALS_ENCRYPTION_KEY
 * is unset — callers must let this propagate as a request failure, never
 * catch-and-fall-back to storing plaintext.
 */
export function encryptCredentials(credentials: Record<string, unknown>): Buffer {
  const key = loadKey();
  const iv = randomBytes(IV_LENGTH_BYTES);
  const cipher = createCipheriv(ALGORITHM, key, iv, { authTagLength: AUTH_TAG_LENGTH_BYTES });
  const plaintext = Buffer.from(JSON.stringify(credentials), 'utf8');
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, authTag, ciphertext]);
}

/**
 * Decrypts a blob produced by encryptCredentials(). Throws on a missing
 * key, a malformed blob, or a failed auth-tag check (tampering/corruption/
 * wrong key) — never returns partial or unauthenticated plaintext.
 */
export function decryptCredentials(blob: Buffer): Record<string, unknown> {
  const key = loadKey();
  if (blob.length < IV_LENGTH_BYTES + AUTH_TAG_LENGTH_BYTES) {
    throw new Error('Encrypted credentials blob is too short to be valid');
  }
  const iv = blob.subarray(0, IV_LENGTH_BYTES);
  const authTag = blob.subarray(IV_LENGTH_BYTES, IV_LENGTH_BYTES + AUTH_TAG_LENGTH_BYTES);
  const ciphertext = blob.subarray(IV_LENGTH_BYTES + AUTH_TAG_LENGTH_BYTES);
  const decipher = createDecipheriv(ALGORITHM, key, iv, { authTagLength: AUTH_TAG_LENGTH_BYTES });
  decipher.setAuthTag(authTag);
  // GCM throws from final() if the auth tag doesn't verify — this IS the
  // tamper/corruption check; there is no separate step to add.
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8')) as Record<string, unknown>;
}
