import { createHash, randomInt, timingSafeEqual } from 'node:crypto';
import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';

// OTP/verification-attempt handling for phone (and, in future, email) OTP
// auth — see verification_attempts in 001_init_schema.sql, which was
// designed for exactly this and never previously used (Phase 8/9 was
// never built until now).
//
// Fixed business-rule constants (not env vars): these are exact product
// decisions, not per-environment tuning knobs — unlike the OTP_*_RATE_LIMIT_*
// values in env.ts, which genuinely vary by deployment/load. MAX_ATTEMPTS
// matches verification_attempts.max_attempts's own DB-level default (5),
// kept here too so the application-level check never silently drifts from
// what a fresh row actually gets.
const OTP_LENGTH = 6;
const OTP_TTL_MINUTES = 5;
const OTP_MAX_ATTEMPTS = 5;
const RESEND_COOLDOWN_SECONDS = 60;

export type VerificationChannel = 'sms' | 'email';
export type VerificationPurpose = 'login' | 'signup' | 'phone_verify' | 'email_verify' | 'account_recovery';

interface RequestOtpParams {
  channel: VerificationChannel;
  target: string; // already E.164-normalized for phone — callers must normalize first
  purpose: VerificationPurpose;
  ipAddress: string | null;
}

function hashCode(code: string): string {
  return createHash('sha256').update(code).digest('hex');
}

/** Cryptographically secure, unbiased 6-digit numeric code (leading zeros
 * preserved) — crypto.randomInt() is rejection-sampled internally, so
 * unlike `Math.random() % 10**6` this has no modulo bias. */
function generateCode(): string {
  const value = randomInt(0, 10 ** OTP_LENGTH);
  return value.toString().padStart(OTP_LENGTH, '0');
}

interface DbVerificationAttemptRow {
  id: string;
  code_hash: string;
  attempts: number;
  max_attempts: number;
  expires_at: Date;
  consumed_at: Date | null;
  created_at: Date;
}

/**
 * Generates and stores a new OTP for (channel, target, purpose), enforcing
 * the 60-second resend cooldown against the most recent prior row for the
 * same (channel, target, purpose). Returns the raw code ONLY for the
 * caller to hand to the SMS provider — never log it, never return it from
 * an API response (see logger.ts's `*.otp`/`*.code` redaction, which is a
 * backstop, not a substitute for not passing it around loosely).
 *
 * Deliberately does NOT send the SMS itself — see phoneOtpService-level
 * caller for why send-failure handling needs to be a separate step (the
 * row must exist before send is attempted so a resend-cooldown/attempt
 * budget applies even if the send itself later fails).
 */
export async function requestOtp(params: RequestOtpParams): Promise<{ code: string }> {
  const { rows } = await pool.query<{ created_at: Date }>(
    `SELECT created_at FROM verification_attempts
     WHERE channel = $1 AND target = $2 AND purpose = $3
     ORDER BY created_at DESC LIMIT 1`,
    [params.channel, params.target, params.purpose],
  );
  const lastAttempt = rows[0];
  if (lastAttempt) {
    const secondsSinceLast = (Date.now() - lastAttempt.created_at.getTime()) / 1000;
    if (secondsSinceLast < RESEND_COOLDOWN_SECONDS) {
      throw HttpError.tooManyRequests('Please wait before requesting another code');
    }
  }

  const code = generateCode();
  const expiresAt = new Date(Date.now() + OTP_TTL_MINUTES * 60_000);

  await pool.query(
    `INSERT INTO verification_attempts (channel, target, purpose, code_hash, max_attempts, expires_at, ip_address)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [params.channel, params.target, params.purpose, hashCode(code), OTP_MAX_ATTEMPTS, expiresAt, params.ipAddress],
  );

  return { code };
}

export type VerifyOtpOutcome =
  | { outcome: 'verified' }
  | { outcome: 'invalid' };

/**
 * Verifies a submitted code against the MOST RECENT verification_attempts
 * row for (channel, target, purpose) — only the latest outstanding code is
 * ever valid, so requesting a fresh OTP implicitly invalidates any earlier
 * one even before it expires (prevents an old, possibly-leaked code from
 * still being usable after a resend).
 *
 * Runs inside a single transaction with `SELECT ... FOR UPDATE` on that
 * row (matches moderationService.ts's takeModerationAction() pattern) —
 * two concurrent verify calls for the same row serialize on the lock, so
 * only one can ever consume it: the second sees consumed_at already set
 * (or attempts already exhausted) once it acquires the lock and returns
 * 'invalid', never a second 'verified'.
 *
 * Every failure path (no row, wrong channel/purpose, already consumed,
 * expired, attempts exhausted, wrong code) returns the SAME 'invalid'
 * outcome — callers must map this to one generic 401, never a
 * distinguishable message, per the enumeration-resistance requirement.
 */
export async function verifyOtp(params: {
  channel: VerificationChannel;
  target: string;
  purpose: VerificationPurpose;
  code: string;
}): Promise<VerifyOtpOutcome> {
  return withTransaction(async (client) => {
    const { rows } = await client.query<DbVerificationAttemptRow>(
      `SELECT id, code_hash, attempts, max_attempts, expires_at, consumed_at, created_at
       FROM verification_attempts
       WHERE channel = $1 AND target = $2 AND purpose = $3
       ORDER BY created_at DESC LIMIT 1
       FOR UPDATE`,
      [params.channel, params.target, params.purpose],
    );
    const row = rows[0];
    if (!row) {
      return { outcome: 'invalid' };
    }
    if (row.consumed_at !== null) {
      return { outcome: 'invalid' };
    }
    if (row.expires_at.getTime() <= Date.now()) {
      return { outcome: 'invalid' };
    }
    if (row.attempts >= row.max_attempts) {
      return { outcome: 'invalid' };
    }

    // Fixed-length SHA-256 hex digests (both always 64 hex chars from
    // hashCode()) — timingSafeEqual is safe here because both buffers are
    // always the same length by construction, not attacker-influenced.
    const submittedHash = Buffer.from(hashCode(params.code), 'hex');
    const storedHash = Buffer.from(row.code_hash, 'hex');
    const matches = submittedHash.length === storedHash.length && timingSafeEqual(submittedHash, storedHash);

    if (matches) {
      await client.query('UPDATE verification_attempts SET consumed_at = now() WHERE id = $1', [row.id]);
      return { outcome: 'verified' };
    }

    const newAttempts = row.attempts + 1;
    const exhausted = newAttempts >= row.max_attempts;
    await client.query(
      `UPDATE verification_attempts
       SET attempts = $1, consumed_at = CASE WHEN $2 THEN now() ELSE consumed_at END
       WHERE id = $3`,
      [newAttempts, exhausted, row.id],
    );
    return { outcome: 'invalid' };
  });
}
