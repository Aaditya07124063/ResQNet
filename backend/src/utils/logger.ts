import pino from 'pino';

// Structured JSON logging. Never log secrets, tokens, passwords, OTP codes,
// or full request/response bodies for security-sensitive routes — pass
// explicit, minimal fields instead of whole objects that might carry them.
export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  redact: {
    paths: [
      'req.headers.authorization',
      'req.headers.cookie',
      '*.password',
      '*.password_hash',
      '*.token',
      '*.idToken',
      '*.accessToken',
      '*.refreshToken',
      '*.code',
      '*.otp',
      '*.privateKey',
      '*.encrypted_credentials',
    ],
    censor: '[redacted]',
  },
});
