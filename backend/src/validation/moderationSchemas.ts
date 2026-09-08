import { z } from 'zod';

// Validated against the exact CHECK constraint on moderation_actions.action_type
// — an invalid value should be a clean 400, not a DB constraint-violation 500.
// 'escalate' is included as a recordable action type (schema-supported) but
// deliberately gets no special escalation WORKFLOW here (no reassignment, no
// notification, no higher-tier routing) — none of that is specified anywhere.
export const takeModerationActionSchema = z.object({
  actionType: z.enum(['dismiss', 'warn', 'suspend_temporary', 'suspend_permanent', 'delete', 'escalate']),
  reason: z
    .string()
    .trim()
    .max(2000)
    .nullable()
    .optional()
    .transform((v) => (v ? v : null)),
});
export type TakeModerationActionInput = z.infer<typeof takeModerationActionSchema>;
