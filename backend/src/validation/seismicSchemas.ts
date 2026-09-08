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
