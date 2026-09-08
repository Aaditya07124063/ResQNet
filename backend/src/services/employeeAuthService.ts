import { randomBytes, createHash } from 'node:crypto';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import { pool } from '../database/pool';
import { env } from '../config/env';
import { HttpError } from '../utils/httpError';
import { getEmployeeByEmailWithPasswordHash, touchEmployeeLastLogin } from './employeeService';
import { toAuthenticatedEmployee, type AuthenticatedEmployee } from '../models/Employee';

interface EmployeeAccessTokenPayload {
  sub: string;
  // Distinguishes an employee token from a consumer-user access token at a
  // glance in logs/debugging — verifyEmployeeAccessToken below does NOT
  // rely on this for security (a different signing secret already makes
  // cross-use impossible); it's a diagnostic aid only.
  kind: 'employee';
}

export interface IssuedEmployeeSession {
  accessToken: string;
  accessTokenExpiresAt: Date;
  refreshToken: string;
  refreshTokenExpiresAt: Date;
}

const BCRYPT_COST = 12;

function hashRefreshToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function signEmployeeAccessToken(employeeId: string): { token: string; expiresAt: Date } {
  const expiresAt = new Date(Date.now() + env.EMPLOYEE_JWT_ACCESS_TTL_MINUTES * 60_000);
  const token = jwt.sign(
    { sub: employeeId, kind: 'employee' } satisfies EmployeeAccessTokenPayload,
    env.EMPLOYEE_JWT_ACCESS_SECRET,
    { expiresIn: `${env.EMPLOYEE_JWT_ACCESS_TTL_MINUTES}m`, algorithm: 'HS256' },
  );
  return { token, expiresAt };
}

/** Mirrors sessionService.ts's issueSession() exactly, scoped to
 * employee_sessions/employees instead of sessions/users (see the
 * migration's own comment for why these are separate tables). */
export async function issueEmployeeSession(
  employeeId: string,
  context: { userAgent: string | null; ipAddress: string | null },
): Promise<IssuedEmployeeSession> {
  const { token: accessToken, expiresAt: accessTokenExpiresAt } = signEmployeeAccessToken(employeeId);

  const refreshToken = randomBytes(48).toString('base64url');
  const refreshTokenExpiresAt = new Date(Date.now() + env.EMPLOYEE_JWT_REFRESH_TTL_DAYS * 86_400_000);

  await pool.query(
    `INSERT INTO employee_sessions (employee_id, refresh_token_hash, expires_at, user_agent, ip_address)
     VALUES ($1, $2, $3, $4, $5)`,
    [employeeId, hashRefreshToken(refreshToken), refreshTokenExpiresAt, context.userAgent, context.ipAddress],
  );

  return { accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt };
}

/** Verifies an employee access token (never a consumer user token — signed
 * with a completely separate secret) and returns the employee id.
 * `algorithms: ['HS256']` pinned explicitly — see sessionService.ts's
 * verifyAccessToken for why (Phase 19 security audit, defense in depth). */
export function verifyEmployeeAccessToken(token: string): string {
  try {
    const payload = jwt.verify(token, env.EMPLOYEE_JWT_ACCESS_SECRET, {
      algorithms: ['HS256'],
    }) as EmployeeAccessTokenPayload;
    if (!payload.sub) throw new Error('missing sub');
    return payload.sub;
  } catch {
    throw HttpError.unauthorized('Invalid or expired employee session token');
  }
}

/**
 * Verifies email+password against `employees.password_hash` (bcrypt) and,
 * on success, issues a session. Returns null on any failure — invalid
 * email, wrong password, or a disabled account are all indistinguishable
 * to the caller (never reveal which one it was, matching the "don't leak
 * whether an email exists" convention used for consumer auth's lack of an
 * enumerable login-by-email path).
 */
export async function loginEmployee(
  email: string,
  password: string,
  context: { userAgent: string | null; ipAddress: string | null },
): Promise<{ employee: AuthenticatedEmployee; session: IssuedEmployeeSession } | null> {
  const row = await getEmployeeByEmailWithPasswordHash(email);
  if (!row || row.status !== 'active') return null;

  const passwordMatches = await bcrypt.compare(password, row.password_hash);
  if (!passwordMatches) return null;

  // Matches authRoutes.ts's Google-login convention: the returned identity
  // reflects the pre-touch row (last_login_at not re-fetched) — the login
  // that just happened, not a fabricated timestamp.
  await touchEmployeeLastLogin(row.id);
  const session = await issueEmployeeSession(row.id, context);
  return { employee: toAuthenticatedEmployee(row), session };
}

export async function hashEmployeePassword(password: string): Promise<string> {
  return bcrypt.hash(password, BCRYPT_COST);
}

/** Mirrors sessionService.ts's rotateRefreshToken() exactly. */
export async function rotateEmployeeRefreshToken(
  refreshToken: string,
  context: { userAgent: string | null; ipAddress: string | null },
): Promise<IssuedEmployeeSession> {
  const tokenHash = hashRefreshToken(refreshToken);
  const { rows } = await pool.query<{ id: string; employee_id: string }>(
    `SELECT id, employee_id FROM employee_sessions
     WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
     LIMIT 1`,
    [tokenHash],
  );
  const session = rows[0];
  if (!session) {
    throw HttpError.unauthorized('Invalid or expired refresh token');
  }

  await pool.query('UPDATE employee_sessions SET revoked_at = now() WHERE id = $1', [session.id]);
  return issueEmployeeSession(session.employee_id, context);
}

export async function revokeEmployeeRefreshToken(refreshToken: string): Promise<void> {
  await pool.query(
    'UPDATE employee_sessions SET revoked_at = now() WHERE refresh_token_hash = $1 AND revoked_at IS NULL',
    [hashRefreshToken(refreshToken)],
  );
}
