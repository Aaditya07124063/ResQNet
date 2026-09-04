import type { IncomingMessage } from 'node:http';
import { verifyAccessToken } from '../services/sessionService';
import { getUserById } from '../services/userService';
import type { AuthenticatedUser } from '../models/User';

/**
 * Verifies the ResQNet access token for a WebSocket upgrade request, the
 * same way requireAuth does for HTTP. The Flutter client sends it as either
 * an `Authorization: Bearer <token>` header on the upgrade request
 * (preferred — dart:io's WebSocket.connect supports custom headers) or an
 * `access_token` query parameter as a fallback for environments that can't
 * set headers.
 */
export async function authenticateUpgrade(req: IncomingMessage): Promise<AuthenticatedUser | null> {
  const authHeader = req.headers.authorization;
  let token: string | undefined;

  if (authHeader?.startsWith('Bearer ')) {
    token = authHeader.slice('Bearer '.length).trim();
  } else if (req.url) {
    const url = new URL(req.url, 'http://internal');
    token = url.searchParams.get('access_token') ?? undefined;
  }

  if (!token) return null;

  try {
    const userId = verifyAccessToken(token);
    const user = await getUserById(userId);
    if (!user || user.accountStatus === 'suspended' || user.accountStatus === 'deleted') return null;
    return user;
  } catch {
    return null;
  }
}
