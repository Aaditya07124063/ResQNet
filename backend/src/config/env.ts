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

  // Phase 15: deliberately SEPARATE secrets from the consumer JWT_* pair
  // above — employees are a separate identity space (see
  // employees/employee_permissions comments in 001_init_schema.sql), so a
  // leaked consumer signing secret must never be usable to forge an
  // employee session, or vice versa.
  EMPLOYEE_JWT_ACCESS_SECRET: z.string().min(32, 'EMPLOYEE_JWT_ACCESS_SECRET must be at least 32 chars'),
  EMPLOYEE_JWT_REFRESH_SECRET: z.string().min(32, 'EMPLOYEE_JWT_REFRESH_SECRET must be at least 32 chars'),
  EMPLOYEE_JWT_ACCESS_TTL_MINUTES: z.coerce.number().int().positive().default(15),
  EMPLOYEE_JWT_REFRESH_TTL_DAYS: z.coerce.number().int().positive().default(30),

  // AES-256-GCM key (32 raw bytes, base64-encoded) for
  // email_providers/sms_providers.encrypted_credentials — see
  // utils/credentialEncryption.ts. Optional at the env-schema level (same
  // graceful-degradation reasoning as FIREBASE_SERVICE_ACCOUNT_JSON/
  // SEISMIC_WEBHOOK_SECRET below: a missing value must not crash app boot
  // in an environment that never touches SMS/email sending, e.g. most
  // tests) — but credentialEncryption.ts itself throws loudly the moment
  // encrypt/decrypt is actually attempted without it. Never logged — see
  // utils/logger.ts redaction.
  PROVIDER_CREDENTIALS_ENCRYPTION_KEY: z.string().optional(),

  // Phase 17: Firebase Admin SDK service-account credentials, used ONLY to
  // call FCM's messaging API server-side (Google's own official Node.js
  // integration for sending to FCM — see docs/AUDIT.md §F: FCM is already
  // the app's only push provider, this doesn't introduce a new one).
  // Deliberately OPTIONAL — this is real, sensitive, per-environment
  // credential material (a downloadable Firebase service-account JSON
  // blob) that this project has no way to fabricate; the push service
  // degrades to a safe no-op (logged, never thrown from the caller's
  // perspective) when absent, exactly like MINIO_*/GOOGLE_OAUTH_CLIENT_ID
  // degrade gracefully before their own real values existed. NEVER log
  // this value — see utils/logger.ts redaction.
  FIREBASE_SERVICE_ACCOUNT_JSON: z.string().optional(),

  // Phase 21 closure: gates POST /api/v1/internal/seismic-alerts — the
  // only caller is functions/index.js's correlateSeismicEvent Cloud
  // Function (service-to-service, no ResQNet user/employee identity of
  // its own), so a shared secret is checked instead of a JWT. Optional,
  // same reasoning as FIREBASE_SERVICE_ACCOUNT_JSON above: absent in
  // local dev, and the route safely 503s rather than accepting requests
  // with no real secret configured. NEVER log this value.
  SEISMIC_WEBHOOK_SECRET: z.string().optional(),

  MINIO_ENDPOINT: z.string().default('127.0.0.1'),
  MINIO_PORT: z.coerce.number().int().positive().default(9000),
  MINIO_USE_SSL: boolFromString,
  // Required now that storageService.ts is active (Phase 6) — a missing
  // value here should fail loudly at boot, not silently fail on the
  // first upload attempt in production.
  MINIO_ACCESS_KEY: z.string().min(1, 'MINIO_ACCESS_KEY is required for profile-image storage'),
  MINIO_SECRET_KEY: z.string().min(1, 'MINIO_SECRET_KEY is required for profile-image storage'),
  MINIO_PROFILE_IMAGES_BUCKET: z.string().default('resqnet-profile-images'),

  RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  RATE_LIMIT_MAX: z.coerce.number().int().positive().default(100),
  SOS_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  SOS_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(5),
  REPORT_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  REPORT_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(10),
  EMPLOYEE_AUTH_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  EMPLOYEE_AUTH_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(10),

  // Phone-OTP auth (Step 2 of the Firebase migration). Two independent
  // limiters per endpoint — IP-keyed (guards a single attacker hammering
  // many numbers) and, for send-otp only, phone-keyed (guards many
  // attackers/devices hammering one victim number) — matching the spec's
  // explicit "rate-limit BOTH IP address and normalized phone number"
  // requirement. verify-otp has no phone-keyed limiter: brute-force against
  // one OTP record is already bounded by verification_attempts.max_attempts
  // (checked/incremented transactionally in verificationService.ts), so a
  // second phone-keyed limiter there would only duplicate that control.
  OTP_SEND_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(900_000),
  OTP_SEND_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(3),
  OTP_SEND_PHONE_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(900_000),
  OTP_SEND_PHONE_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(3),
  OTP_VERIFY_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(900_000),
  OTP_VERIFY_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(10),

  // Communication phase (chat): message sending is much higher-frequency
  // than SOS/reports by nature, so it gets its own, more generous budget
  // rather than sharing SOS_RATE_LIMIT_* or the general default.
  MESSAGE_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  MESSAGE_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(60),
  CONVERSATION_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  CONVERSATION_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(20),

  // Nearby emergency alerts: the single, clearly-defined place the alert
  // radius lives — never hard-coded at each call site. A user's own
  // nearby_emergency_preferences.radius_m overrides this per-user; this is
  // only the fallback when that column is NULL. Kept modest (a few
  // kilometers) since this notifies strangers, not trusted contacts.
  NEARBY_ALERT_DEFAULT_RADIUS_M: z.coerce.number().int().positive().default(5_000),
  NEARBY_ALERT_RATE_LIMIT_WINDOW_MS: z.coerce.number().int().positive().default(60_000),
  NEARBY_ALERT_RATE_LIMIT_MAX: z.coerce.number().int().positive().default(20),

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
