import { z } from 'zod';

export const ALERT_SOURCE_TYPES = [
  'official', 'verified_partner', 'international_public', 'resqnet_system', 'community', 'device_sensor',
] as const;
export const ALERT_CATEGORIES = [
  'flood', 'earthquake', 'landslide', 'wildfire', 'storm', 'avalanche', 'evacuation', 'shelter', 'road_closure', 'health', 'other',
] as const;
export const ALERT_SEVERITIES = ['info', 'advisory', 'watch', 'warning', 'emergency'] as const;

const area = {
  latitude: z.number().min(-90).max(90).optional(),
  longitude: z.number().min(-180).max(180).optional(),
  radiusKm: z.number().positive().max(1000).optional(),
  province: z.string().trim().min(1).max(80).optional(),
  district: z.string().trim().min(1).max(80).optional(),
  municipality: z.string().trim().min(1).max(120).optional(),
};

const circleIsComplete = (v: { latitude?: number; longitude?: number; radiusKm?: number }) => {
  const set = [v.latitude, v.longitude, v.radiusKm].filter((x) => x !== undefined).length;
  return set === 0 || set === 3;
};

/** Portal-issued alert. Only these source types can be issued by staff;
 * community and device-sensor alerts come from other pipelines. */
export const createAlertSchema = z
  .object({
    sourceType: z.enum(['official', 'verified_partner', 'resqnet_system']),
    sourceName: z.string().trim().min(2).max(160),
    category: z.enum(ALERT_CATEGORIES),
    severity: z.enum(ALERT_SEVERITIES),
    title: z.string().trim().min(3).max(200),
    body: z.string().trim().min(1).max(4000),
    instructions: z.string().trim().max(2000).optional(),
    expiresAt: z.string().datetime().optional(),
    /** Public page with the original notice, if any. */
    sourceUrl: z.string().trim().url().max(500).startsWith('https://').optional(),
    ...area,
  })
  .refine(circleIsComplete, { message: 'latitude, longitude and radiusKm must be given together', path: ['radiusKm'] })
  .refine((v) => v.latitude !== undefined || v.province !== undefined || v.district !== undefined, {
    message: 'An alert needs a geographic scope (a circle or an administrative area)',
    path: ['latitude'],
  });

export const updateAlertSchema = z
  .object({
    severity: z.enum(ALERT_SEVERITIES).optional(),
    title: z.string().trim().min(3).max(200).optional(),
    body: z.string().trim().min(1).max(4000).optional(),
    instructions: z.string().trim().max(2000).nullable().optional(),
    expiresAt: z.string().datetime().nullable().optional(),
    status: z.enum(['active', 'resolved', 'cancelled']).optional(),
  })
  .refine((v) => Object.values(v).some((x) => x !== undefined), 'At least one update is required');

export type CreateAlertInput = z.infer<typeof createAlertSchema>;
export type UpdateAlertInput = z.infer<typeof updateAlertSchema>;
