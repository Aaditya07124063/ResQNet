import type { Server as HttpServer } from 'node:http';
import { WebSocketServer, type WebSocket } from 'ws';
import { env } from '../config/env';
import { logger } from '../utils/logger';
import { authenticateUpgrade } from './wsAuth';
import type { AuthenticatedUser } from '../models/User';

export interface AuthenticatedWebSocket extends WebSocket {
  authUser: AuthenticatedUser;
}

// userId -> live sockets (a user may have more than one device connected).
const connections = new Map<string, Set<AuthenticatedWebSocket>>();

export function broadcastToUser(userId: string, payload: unknown): void {
  const sockets = connections.get(userId);
  if (!sockets) return;
  const data = JSON.stringify(payload);
  for (const socket of sockets) {
    if (socket.readyState !== socket.OPEN) continue;
    try {
      socket.send(data);
    } catch (err) {
      // Best-effort delivery — one misbehaving socket must never stop
      // delivery to this user's other connected devices.
      logger.warn({ err, userId }, 'WebSocket send failed');
    }
  }
}

// Phase 19 security audit: `ws` defaults to a 100MiB maxPayload when
// unset — this connection is server-push-only today (no inbound command
// protocol exists at all, see the 'message' handler below), so there is
// no legitimate reason for an authenticated client to ever send anything
// large. 16KB is generous headroom for a future small JSON command while
// closing off a real memory/CPU DoS vector (an authenticated client
// repeatedly sending huge frames for JSON.parse to churn on).
const MAX_WS_PAYLOAD_BYTES = 16 * 1024;

// Phase 19 security audit: the raw `http.Server` 'upgrade' event fires
// entirely outside Express — none of app.ts's rate limiters (which key
// off req.authUser, set later by Express-only middleware) ever see this
// path, so without a limiter here, upgrade attempts (each costing a
// verifyAccessToken + a DB getUserById call) are completely unbounded.
// A minimal in-memory sliding-window counter, keyed by the raw socket
// remote address — this doesn't parse X-Forwarded-For (unlike Express's
// `trust proxy` handling), so behind nginx every real client currently
// shares nginx's own address for this specific counter; still meaningfully
// bounds a single abusive connection/script hammering this endpoint.
const UPGRADE_RATE_LIMIT_WINDOW_MS = 60_000;
const UPGRADE_RATE_LIMIT_MAX = 30;
const upgradeAttemptsByIp = new Map<string, { count: number; windowStart: number }>();

function isUpgradeRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = upgradeAttemptsByIp.get(ip);
  if (!entry || now - entry.windowStart >= UPGRADE_RATE_LIMIT_WINDOW_MS) {
    upgradeAttemptsByIp.set(ip, { count: 1, windowStart: now });
    return false;
  }
  entry.count += 1;
  return entry.count > UPGRADE_RATE_LIMIT_MAX;
}

/** Test-only: every test in this file's suite connects from the same
 * loopback address (binding a Node WS client to another 127.0.0.0/8
 * address isn't portable — it fails with EADDRNOTAVAIL on macOS unless
 * that address is explicitly configured), so tests reset this counter
 * between runs instead of relying on address isolation. Not used by any
 * production code path. */
export function resetUpgradeRateLimiterForTests(): void {
  upgradeAttemptsByIp.clear();
}

export function attachWebSocketServer(httpServer: HttpServer): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_WS_PAYLOAD_BYTES });

  httpServer.on('upgrade', (req, socket, head) => {
    const { pathname } = new URL(req.url ?? '', 'http://internal');
    if (pathname !== env.WS_PATH) {
      socket.destroy();
      return;
    }

    const remoteAddress = req.socket.remoteAddress ?? 'unknown';
    if (isUpgradeRateLimited(remoteAddress)) {
      socket.write('HTTP/1.1 429 Too Many Requests\r\n\r\n');
      socket.destroy();
      return;
    }

    authenticateUpgrade(req)
      .then((authUser) => {
        if (!authUser) {
          // 401 on a raw upgrade socket — no body, matches HTTP semantics
          // without leaking details about why auth failed.
          socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
          socket.destroy();
          return;
        }
        wss.handleUpgrade(req, socket, head, (ws) => {
          (ws as AuthenticatedWebSocket).authUser = authUser;
          wss.emit('connection', ws, req);
        });
      })
      .catch((err) => {
        logger.error({ err }, 'WebSocket upgrade authentication failed');
        socket.destroy();
      });
  });

  wss.on('connection', (ws: AuthenticatedWebSocket) => {
    const userId = ws.authUser.id;
    if (!connections.has(userId)) connections.set(userId, new Set());
    connections.get(userId)!.add(ws);
    logger.info({ userId }, 'WebSocket connected');

    ws.on('close', () => {
      connections.get(userId)?.delete(ws);
      if (connections.get(userId)?.size === 0) connections.delete(userId);
      logger.info({ userId }, 'WebSocket disconnected');
    });

    ws.on('error', (err) => {
      logger.warn({ err, userId }, 'WebSocket error');
    });

    // No inbound client command protocol is specified anywhere in this
    // project yet (Phase 12 only justifies server -> client SOS delivery
    // — see sosService.ts) — this connection is server-push-only for now.
    // A handler still needs to exist so a malformed/unexpected inbound
    // message can never crash the connection or leak internals; it never
    // logs the raw payload (could contain arbitrary client data).
    ws.on('message', (data) => {
      let parsed: unknown;
      try {
        parsed = JSON.parse(data.toString());
      } catch {
        logger.warn({ userId }, 'Received non-JSON WebSocket message — ignored');
        return;
      }
      logger.debug({ userId, type: (parsed as { type?: unknown })?.type }, 'Received WebSocket message — ignored (no inbound command protocol defined yet)');
    });
  });

  return wss;
}
