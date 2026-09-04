import { pool } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { type AuthenticatedUser, type DbUserRow, toAuthenticatedUser } from '../models/User';

/**
 * Maps a verified Google `sub` claim to a users row, creating one on first
 * sight. This is the ONLY place a ResQNet user id is derived from a Google
 * identity — every other authorization check trusts req.authUser.id, never
 * a client-supplied field.
 */
export async function findOrCreateUserByGoogleSubject(
  googleSubject: string,
  claims: { email: string | null; emailVerified: boolean; displayName: string | null },
): Promise<AuthenticatedUser> {
  const { rows } = await pool.query<DbUserRow>(
    'SELECT * FROM users WHERE google_subject = $1 LIMIT 1',
    [googleSubject],
  );
  if (rows[0]) {
    return toAuthenticatedUser(rows[0]);
  }

  // Concurrent first sign-in from the same account can race this insert;
  // ON CONFLICT DO NOTHING + a follow-up SELECT makes it idempotent without
  // a transaction/advisory lock.
  await pool.query(
    `INSERT INTO users (google_subject, email, email_verified, display_name)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (google_subject) DO NOTHING`,
    [googleSubject, claims.email, claims.emailVerified, claims.displayName],
  );

  const { rows: created } = await pool.query<DbUserRow>(
    'SELECT * FROM users WHERE google_subject = $1 LIMIT 1',
    [googleSubject],
  );
  const row = created[0];
  if (!row) {
    throw HttpError.internal('Failed to provision user record');
  }
  return toAuthenticatedUser(row);
}

export async function getUserById(id: string): Promise<AuthenticatedUser | null> {
  const { rows } = await pool.query<DbUserRow>('SELECT * FROM users WHERE id = $1 LIMIT 1', [id]);
  return rows[0] ? toAuthenticatedUser(rows[0]) : null;
}

export async function touchLastLogin(userId: string): Promise<void> {
  await pool.query('UPDATE users SET last_login_at = now() WHERE id = $1', [userId]);
}
