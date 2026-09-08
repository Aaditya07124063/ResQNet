import { z } from 'zod';

// reason has no CHECK/enum constraint in the schema (user_reports.reason is
// a plain VARCHAR(60)) — validated here only against what the column
// itself actually allows (non-empty, <=60 chars), not against an invented
// fixed category list the database doesn't enforce.
export const createReportSchema = z.object({
  reportedUserId: z.string().uuid(),
  reason: z.string().trim().min(1).max(60),
  description: z
    .string()
    .trim()
    .max(2000)
    .nullable()
    .optional()
    .transform((v) => (v ? v : null)),
});
