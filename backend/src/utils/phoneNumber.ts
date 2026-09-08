import { parsePhoneNumberFromString } from 'libphonenumber-js';

// No existing dependency in this codebase can safely parse/normalize phone
// numbers (confirmed by audit — no libphonenumber-js/google-libphonenumber
// or equivalent was present before this file). libphonenumber-js is the
// standard, actively-maintained JS port of Google's libphonenumber; used
// here ONLY for E.164 normalization/validation, not for anything else.
//
// DEFAULT_REGION is Nepal ('NP') — ResQNet's primary user base — so a
// national-format input like "98XXXXXXXX" is interpreted as a Nepali
// number. An input already carrying a country code (e.g. "+91...",
// "+977...") normalizes correctly regardless of this default; it only
// affects numbers with no leading '+'.
const DEFAULT_REGION = 'NP';

/**
 * Normalizes a user-supplied phone number to E.164 (e.g. "+9779812345678").
 * Returns null for anything that isn't a valid, dialable number — never
 * throws, so callers can treat null as "reject this input" uniformly.
 *
 * Normalizing BEFORE rate-limiting/lookup is what prevents formatting
 * variants (spaces, dashes, a leading "00" vs "+", etc.) of the same real
 * number from being treated as distinct targets for rate-limit or
 * verification-attempt purposes — see verificationService.ts.
 */
export function normalizePhoneNumber(rawInput: string): string | null {
  if (typeof rawInput !== 'string' || rawInput.length === 0 || rawInput.length > 32) {
    return null;
  }
  let parsed;
  try {
    parsed = parsePhoneNumberFromString(rawInput, DEFAULT_REGION);
  } catch {
    return null;
  }
  if (!parsed || !parsed.isValid()) {
    return null;
  }
  return parsed.number; // E.164, e.g. "+9779812345678"
}
