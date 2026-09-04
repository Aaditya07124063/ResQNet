import { createApp } from './app';
import { env } from './config/env';
import { logger } from './utils/logger';
import { attachWebSocketServer } from './websocket/wsServer';
import { pool } from './database/pool';

const app = createApp();
const httpServer = app.listen(env.PORT, env.HOST, () => {
  logger.info({ port: env.PORT, host: env.HOST, env: env.NODE_ENV }, 'ResQNet backend listening');
});

attachWebSocketServer(httpServer);

async function shutdown(signal: string): Promise<void> {
  logger.info({ signal }, 'Shutting down');
  httpServer.close(() => {
    logger.info('HTTP server closed');
  });
  await pool.end();
  process.exit(0);
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
