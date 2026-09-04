import { z } from 'zod';
import dotenv from 'dotenv';

dotenv.config();

const boolFromString = z
  .string()
  .optional()
  .transform((v) => v === 'true');

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'staging', 'production', 'test']).default('development'),
  PORT: z.coerce.number().int().positive().default(4000),
  HOST: z.string().default('0.0.0.0'),
  PUBLIC_BASE_URL: z.string().default('http://localhost:4000'),

  CORS_ORIGINS: z.string().default(''),

  PG_HOST: z.string().default('127.0.0.1'),
  PG_PORT: z.coerce.number().int().positive().default(5432),
  PG_USER: z.string(),
  PG_PASSWORD: z.string(),
  PG_DATABASE: z.string(),
  PG_POOL_MAX: z.coerce.number().int().positive().default(10),
  PG_SSL: boolFromString,

  GOOGLE_OAUTH_CLIENT_ID: z.string().min(1, 'GOOGLE_OAUTH_CLIENT_ID is required to verify Google ID tokens'),

  JWT_ACCESS_SECRET: z.string().min(32, 'JWT_ACCESS_SECRET must be at least 32 chars'),
  JWT_REFRESH_SECRET: z.string().min(32, 'JWT_REFRESH_SECRET must be at least 32 chars'),
  JWT_ACCESS_TTL_MINUTES: z.coerce.number().int().positive().default(15),
  JWT_REFRESH_TTL_DAYS: z.coerce.number().int().positive().default(30),

  PROVIDER_CREDENTIALS_ENCRYPTION_KEY: z.string().optional(),

  MINIO_ENDPOINT: z.string().default('127.0.0.1'),
  MINIO_PORT: z.coerce.number().int().positive().default(9000),
  MINIO_USE_SSL: boolFromString,
  MINIO_ACCESS_KEY: z.string().optional(),
  MINIO_SECRET_KEY: z.string().optional(),
  MINIO_PROFILE_IMAGES_BUCKET: z.string().default('resqnet-profile-images'),

  RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  RATE_LIMIT_MAX: z.coerce.number().int().positive().default(100),
  SOS_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  SOS_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(5),

  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),

  TRUSTED_PROXY_HOPS: z.coerce.number().int().min(0).default(1),

  WS_PATH: z.string().default('/ws'),
});

export type Env = z.infer<typeof envSchema>;

function loadEnv(): Env {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    // eslint-disable-next-line no-console
    console.error('Invalid environment configuration:', parsed.error.flatten().fieldErrors);
    throw new Error('Invalid environment configuration — see logged field errors above.');
  }
  return parsed.data;
}

export const env = loadEnv();

export const corsOrigins = env.CORS_ORIGINS.split(',')
  .map((s) => s.trim())
  .filter(Boolean);

export const isProduction = env.NODE_ENV === 'production';
