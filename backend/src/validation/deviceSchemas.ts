import { z } from 'zod';

// `pushProvider` has no CHECK constraint in the schema — it's a free-text
// column specifically so this schema doesn't need to pre-commit to a
// fixed provider list (see the column's own doc comment in
// 001_init_schema.sql). `platform` DOES have a CHECK constraint, so it's
// validated against that exact set — an invalid value here should be a
// clean 400, not a DB constraint-violation 500.
export const registerDeviceSchema = z.object({
  platform: z.enum(['android', 'ios', 'web']),
  pushProvider: z.string().trim().min(1).max(40),
  pushToken: z.string().trim().min(1).max(4096),
});
export type RegisterDeviceInput = z.infer<typeof registerDeviceSchema>;
