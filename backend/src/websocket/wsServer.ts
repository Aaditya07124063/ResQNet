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
    if (socket.readyState === socket.OPEN) socket.send(data);
  }
}

export function attachWebSocketServer(httpServer: HttpServer): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on('upgrade', (req, socket, head) => {
    const { pathname } = new URL(req.url ?? '', 'http://internal');
    if (pathname !== env.WS_PATH) {
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
  });

  return wss;
}
