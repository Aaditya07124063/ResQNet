import express, { type Express } from 'express';
import helmet from 'helmet';
import cors from 'cors';
import pinoHttp from 'pino-http';
import { corsOrigins, env, isProduction } from './config/env';
import { logger } from './utils/logger';
import { defaultRateLimiter } from './middleware/rateLimiter';
import { errorHandler, notFoundHandler } from './middleware/errorHandler';
import { router } from './routes';

export function createApp(): Express {
  const app = express();

  app.set('trust proxy', env.TRUSTED_PROXY_HOPS);
  app.disable('x-powered-by');

  app.use(helmet());
  app.use(
    cors({
      origin: (origin, callback) => {
        // Same-origin / server-to-server requests have no Origin header.
        if (!origin) return callback(null, true);
        if (corsOrigins.includes(origin)) return callback(null, true);
        if (!isProduction && corsOrigins.length === 0) return callback(null, true);
        callback(new Error('Not allowed by CORS'));
      },
      credentials: false,
    }),
  );

  app.use(
    pinoHttp({
      logger,
      redact: ['req.headers.authorization'],
    }),
  );

  // Reject oversized payloads outright — SOS/location/message bodies are
  // small; 100kb is generous headroom without allowing abuse uploads.
  // Profile-picture bytes never pass through JSON bodies (MinIO upload is
  // multipart/binary, handled by its own route in Phase 6 with its own limit).
  app.use(express.json({ limit: '100kb' }));

  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', env: env.NODE_ENV });
  });

  app.use('/api/v1', defaultRateLimiter, router);

  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}
