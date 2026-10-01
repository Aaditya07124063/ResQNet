import { z } from 'zod';

// Mirrors exactly what functions/index.js's correlateSeismicEvent already
// has in hand once it decides an event is corroborated — nothing new is
// derived or invented here.
export const seismicCorroborationAlertSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  deviceCount: z.number().int().min(1),
});
export type SeismicCorroborationAlertInput = z.infer<typeof seismicCorroborationAlertSchema>;

/** A device's local earthquake candidate (POST /api/v1/seismic/reports).
 * Location is required — an unlocated report cannot be clustered. */
export const seismicReportSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  detectorScore: z.number().min(0).max(1),
  staLtaRatio: z.number().min(0).max(1000).optional(),
  sustainedDurationMs: z.number().int().min(0).max(600_000).optional(),
  oscillationCount: z.number().int().min(0).max(100_000).optional(),
});
export type SeismicReportInput = z.infer<typeof seismicReportSchema>;
