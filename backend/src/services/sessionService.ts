import { randomBytes, createHash } from 'node:crypto';
import jwt from 'jsonwebtoken';
import { pool } from '../database/pool';
import { env } from '../config/env';
import { HttpError } from '../utils/httpError';

interface AccessTokenPayload {
  sub: string;
}

export interface IssuedSession {
  accessToken: string;
  accessTokenExpiresAt: Date;
  refreshToken: string;
  refreshTokenExpiresAt: Date;
}

function hashRefreshToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function signAccessToken(userId: string): { token: string; expiresAt: Date } {
  const expiresAt = new Date(Date.now() + env.JWT_ACCESS_TTL_MINUTES * 60_000);
  const token = jwt.sign({ sub: userId } satisfies AccessTokenPayload, env.JWT_ACCESS_SECRET, {
    expiresIn: `${env.JWT_ACCESS_TTL_MINUTES}m`,
    algorithm: 'HS256',
  });
  return { token, expiresAt };
}

/**
 * Issues a fresh access+refresh token pair for a user (e.g. after Google
 * ID token / phone OTP verification). The refresh token itself is never
 * stored — only its SHA-256 hash — so a database read alone can't be used
 * to mint sessions.
 */
export async function issueSession(
  userId: string,
  context: { userAgent: string | null; ipAddress: string | null },
): Promise<IssuedSession> {
  const { token: accessToken, expiresAt: accessTokenExpiresAt } = signAccessToken(userId);

  const refreshToken = randomBytes(48).toString('base64url');
  const refreshTokenExpiresAt = new Date(Date.now() + env.JWT_REFRESH_TTL_DAYS * 86_400_000);

  await pool.query(
    `INSERT INTO sessions (user_id, refresh_token_hash, expires_at, user_agent, ip_address)
     VALUES ($1, $2, $3, $4, $5)`,
    [userId, hashRefreshToken(refreshToken), refreshTokenExpiresAt, context.userAgent, context.ipAddress],
  );

  return { accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt };
}

/** Verifies a ResQNet access token (not a refresh token) and returns the
 * authenticated user id. Used by requireAuth on every protected request.
 * `algorithms: ['HS256']` is pinned explicitly (Phase 19 security audit) —
 * defense in depth: without it, a verifier accepts whatever algorithm the
 * token's own header claims is compatible with the key type given. Since
 * the key here is a plain string (HMAC-only), jsonwebtoken already
 * rejects an RS/ES-family token, but pinning removes any ambiguity rather
 * than relying on that inference. */
export function verifyAccessToken(token: string): string {
  try {
    const payload = jwt.verify(token, env.JWT_ACCESS_SECRET, { algorithms: ['HS256'] }) as AccessTokenPayload;
    if (!payload.sub) throw new Error('missing sub');
    return payload.sub;
  } catch {
    throw HttpError.unauthorized('Invalid or expired session token');
  }
}

/**
 * Rotates a refresh token: the presented token must match an unrevoked,
 * unexpired session row. That row is revoked and a brand-new access+refresh
 * pair is issued — rotation (rather than reuse) means a stolen refresh
 * token only works once before the legitimate client's next refresh
 * invalidates it, surfacing the theft.
 */
export async function rotateRefreshToken(
  refreshToken: string,
  context: { userAgent: string | null; ipAddress: string | null },
): Promise<IssuedSession> {
  const tokenHash = hashRefreshToken(refreshToken);
  const { rows } = await pool.query<{ id: string; user_id: string }>(
    `SELECT id, user_id FROM sessions
     WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
     LIMIT 1`,
    [tokenHash],
  );
  const session = rows[0];
  if (!session) {
    throw HttpError.unauthorized('Invalid or expired refresh token');
  }

  await pool.query('UPDATE sessions SET revoked_at = now() WHERE id = $1', [session.id]);
  return issueSession(session.user_id, context);
}

export async function revokeRefreshToken(refreshToken: string): Promise<void> {
  await pool.query('UPDATE sessions SET revoked_at = now() WHERE refresh_token_hash = $1 AND revoked_at IS NULL', [
    hashRefreshToken(refreshToken),
  ]);
}
