import { OAuth2Client } from 'google-auth-library';
import { env } from '../config/env';
import { HttpError } from '../utils/httpError';

const client = new OAuth2Client();

export interface VerifiedGoogleIdentity {
  /** Google's stable per-account identifier (the `sub` claim). Use this,
   * never email, as the durable identity key — emails can change. */
  subject: string;
  email: string | null;
  emailVerified: boolean;
  displayName: string | null;
}

/**
 * Verifies a Google ID token the Flutter client obtained via Google
 * Sign-In (the current `google_sign_in` v7+ / "Sign in with Google" flow
 * — see docs/AUDIT.md for the version-history note). Uses the official
 * google-auth-library, which checks the JWT signature against Google's
 * public keys plus the `aud`, `iss`, and `exp` claims — no custom
 * cryptography, per project policy.
 */
export async function verifyGoogleIdToken(idToken: string): Promise<VerifiedGoogleIdentity> {
  let ticket;
  try {
    ticket = await client.verifyIdToken({
      idToken,
      audience: env.GOOGLE_OAUTH_CLIENT_ID,
    });
  } catch {
    throw HttpError.unauthorized('Invalid or expired Google ID token');
  }

  const payload = ticket.getPayload();
  if (!payload?.sub) {
    throw HttpError.unauthorized('Google ID token missing subject claim');
  }

  return {
    subject: payload.sub,
    email: payload.email ?? null,
    emailVerified: payload.email_verified ?? false,
    displayName: payload.name ?? null,
  };
}
