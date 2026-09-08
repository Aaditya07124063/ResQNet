import { z } from 'zod';
import { originEnvelopeSchema } from './originEnvelopeSchema';

// `category` has no CHECK constraint in the schema (sos_events.category is
// a plain VARCHAR(40)) — validated here only against what the column
// itself allows, not an invented fixed list (same reasoning as
// reportSchemas.ts's `reason` field). `eventSource` DOES have a CHECK
// constraint, so it's validated against that exact set — an invalid value
// here should be a clean 400, not a DB constraint-violation 500.
//
// `originEnvelope` (optional) is the cryptographic-origin-authentication
// path: a mesh relay device uploading a signed SOS on behalf of a
// different, possibly-offline origin device. When present, it is the
// SOLE source of truth for the event's content (category/message/
// coordinates/etc. all live inside it, signed) — the top-level fields
// below become irrelevant and are not required, but are NOT removed from
// this schema, because the direct (non-relayed, today's existing) path —
// the authenticated caller creating their OWN event — still uses them
// exactly as before this feature existed. This keeps ONE endpoint and ONE
// schema for both paths rather than a second, parallel SOS API.
export const createSosEventSchema = z
  .object({
    eventId: z.string().uuid(),
    eventSource: z.enum(['manual', 'crash_detection', 'earthquake_detection']).optional(),
    category: z.string().trim().min(1).max(40).optional(),
    message: z
      .string()
      .trim()
      .max(2000)
      .nullable()
      .optional()
      .transform((v) => (v ? v : null)),
    latitude: z.number().min(-90).max(90).nullable().optional().transform((v) => v ?? null),
    longitude: z.number().min(-180).max(180).nullable().optional().transform((v) => v ?? null),
    locationAccuracyM: z.number().nonnegative().nullable().optional().transform((v) => v ?? null),
    clientCreatedAt: z.coerce.date().optional(),
    originEnvelope: originEnvelopeSchema.optional(),
  })
  .superRefine((data, ctx) => {
    // The direct path's required fields are validated here, conditionally,
    // rather than being unconditionally `.required()` on the object —
    // that's what lets originEnvelope's own, separately-validated fields
    // stand in for them on the relayed path instead.
    if (data.originEnvelope) return;
    if (!data.eventSource) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['eventSource'], message: 'Required' });
    }
    if (!data.category) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['category'], message: 'Required' });
    }
    if (!data.clientCreatedAt) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['clientCreatedAt'], message: 'Required' });
    }
  });
export type CreateSosEventInput = z.infer<typeof createSosEventSchema>;

/** True for the direct (non-relayed) creation path — the authenticated
 * caller IS the reporter. Narrows the optional direct-path fields back to
 * required. Checks the fields themselves (not just "no originEnvelope")
 * so the type guard is sound on its own terms rather than relying solely
 * on `createSosEventSchema`'s superRefine having already run — callers
 * still get a clear error rather than a runtime crash if that invariant
 * were ever violated. */
export function isDirectSosEventInput(
  input: CreateSosEventInput,
): input is CreateSosEventInput & { eventSource: NonNullable<CreateSosEventInput['eventSource']>; category: string; clientCreatedAt: Date } {
  return !input.originEnvelope && input.eventSource !== undefined && input.category !== undefined && input.clientCreatedAt !== undefined;
}

// 'open' is deliberately excluded — it's the server-assigned initial
// state, never a client-chosen transition target.
export const updateSosEventStatusSchema = z.object({
  status: z.enum(['acknowledged', 'resolved', 'false_alarm']),
});
export type UpdateSosEventStatusInput = z.infer<typeof updateSosEventStatusSchema>;
