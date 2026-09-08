import { z } from 'zod';

export const updateNearbyPreferenceSchema = z.object({
  enabled: z.boolean(),
  // Extensibility point (Section 13) — a per-user radius override.
  // Omitted/NULL means "use the server default" (env.NEARBY_ALERT_DEFAULT_RADIUS_M).
  radiusM: z.number().int().min(100).max(50_000).nullable().optional().transform((v) => v ?? null),
});
export type UpdateNearbyPreferenceInput = z.infer<typeof updateNearbyPreferenceSchema>;

export const updateNearbyLocationSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});
export type UpdateNearbyLocationInput = z.infer<typeof updateNearbyLocationSchema>;
