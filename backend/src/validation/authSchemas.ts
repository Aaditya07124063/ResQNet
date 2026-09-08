import { z } from 'zod';
import { normalizePhoneNumber } from '../utils/phoneNumber';

// Shared shape/transform: bounds the raw input BEFORE it ever reaches
// libphonenumber-js, then normalizes to E.164 here (not in the route
// handler) so every downstream consumer — the phone-keyed rate limiter,
// verificationService, phoneAuthService — already sees the canonical form.
// This is what makes rate-limiting/lookup immune to formatting variants of
// the same real number (spaces, dashes, a leading "00" vs "+", etc.) — see
// utils/phoneNumber.ts's own comment.
const phoneNumberField = z
  .string()
  .min(6)
  .max(20)
  .regex(/^[0-9+\-() ]+$/, 'Phone number contains invalid characters')
  .transform((raw, ctx) => {
    const normalized = normalizePhoneNumber(raw);
    if (!normalized) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'Phone number is not a valid, dialable number' });
      return z.NEVER;
    }
    return normalized;
  });

export const googleSignInSchema = z.object({
  idToken: z.string().min(20).max(4096),
});

export const refreshSchema = z.object({
  refreshToken: z.string().min(20).max(512),
});

export const sendOtpSchema = z.object({
  phoneNumber: phoneNumberField,
});

// Exactly 6 numeric digits, matching the fixed OTP_LENGTH decision in
// verificationService.ts — a stricter length here (rather than a generic
// "string, max N") is deliberate: it rejects malformed/oversized input
// before it reaches any hashing/DB comparison.
export const verifyOtpSchema = z.object({
  phoneNumber: phoneNumberField,
  code: z.string().regex(/^\d{6}$/, 'Code must be exactly 6 digits'),
});
