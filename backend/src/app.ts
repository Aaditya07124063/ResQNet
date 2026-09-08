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
      // pino-http's own `redact` option is separate from the `logger`
      // instance's own redact config (utils/logger.ts) — it is NOT
      // merged with it, so a header that must never reach the access
      // log (e.g. the seismic webhook secret, Phase 21 closure) has to
      // be listed here too, or it is logged in cleartext on every
      // request regardless of logger.ts's own redact list. Confirmed by
      // a live request during Phase 21 closure: logger.ts alone did not
      // redact this header from the request-completed log line.
      redact: ['req.headers.authorization', 'req.headers["x-seismic-webhook-secret"]'],
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
