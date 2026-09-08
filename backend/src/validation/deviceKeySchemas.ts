import { z } from 'zod';

// `algorithm` has exactly one supported value today. It's still an
// explicit field (not hardcoded server-side) so a future algorithm
// addition is additive, matching the project's general "no hardcoded
// single-vendor assumption" pattern (email/SMS provider interfaces) —
// but only 'ECDSA_P256_SHA256' is accepted until origin verification
// actually supports anything else (utils/originSignature.ts).
export const registerDeviceKeySchema = z.object({
  deviceId: z.string().uuid(),
  keyId: z.string().min(1).max(64),
  publicKey: z.string().min(1).max(2000),
  algorithm: z.literal('ECDSA_P256_SHA256'),
});
export type RegisterDeviceKeyInput = z.infer<typeof registerDeviceKeySchema>;
