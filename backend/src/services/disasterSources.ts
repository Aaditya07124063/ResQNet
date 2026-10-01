import { z } from 'zod';
import { pool } from '../database/pool';
import { logger } from '../utils/logger';
import { ALERT_CATEGORIES, ALERT_SEVERITIES } from '../validation/alertSchemas';

// Adapter architecture for external disaster/alert feeds:
//
//   external source → adapter (fetch + map to NormalizedAlert)
//     → validation → emergency_alerts (PostgreSQL) → app / portal
//
// An adapter declares its own source identity; the ingester stamps it on
// every alert, so a feed's payload can never claim to be someone else.
// No adapter is registered by default: a source is only added after its
// API, terms of use, and reliability have been verified (see
// docs/DISASTER_SOURCES.md). Nothing here fabricates alerts.

export interface NormalizedAlert {
  externalId: string;
  category: (typeof ALERT_CATEGORIES)[number];
  severity: (typeof ALERT_SEVERITIES)[number];
  title: string;
  body: string;
  instructions?: string;
  latitude?: number;
  longitude?: number;
  radiusKm?: number;
  province?: string;
  district?: string;
  issuedAt?: string;
  expiresAt?: string;
  /** The source says this alert is over. */
  ended?: boolean;
  /** Public https page for this item in the source, if it has one. */
  sourceUrl?: string;
}

export interface DisasterSourceAdapter {
  /** Shown to users as the issuer, e.g. the authority or feed name. */
  readonly sourceName: string;
  /**
   * Only an authority's own feed may be 'official'. Public international
   * feeds (not a Nepali authority, no agreement) are 'international_public'.
   */
  readonly sourceType: 'official' | 'verified_partner' | 'international_public';
  /** Public page describing the source (https). */
  readonly homepageUrl?: string;
  /** Whether the source's terms of use were checked for this use. */
  readonly terms?: { status: 'verified' | 'pending' | 'unknown'; note?: string };
  fetchAlerts(): Promise<NormalizedAlert[]>;
}

const normalizedAlertSchema = z
  .object({
    externalId: z.string().trim().min(1).max(200),
    category: z.enum(ALERT_CATEGORIES),
    severity: z.enum(ALERT_SEVERITIES),
    title: z.string().trim().min(3).max(200),
    body: z.string().trim().min(1).max(4000),
    instructions: z.string().trim().max(2000).optional(),
    latitude: z.number().min(-90).max(90).optional(),
    longitude: z.number().min(-180).max(180).optional(),
    radiusKm: z.number().positive().max(1000).optional(),
    province: z.string().trim().max(80).optional(),
    district: z.string().trim().max(80).optional(),
    issuedAt: z.string().datetime().optional(),
    expiresAt: z.string().datetime().optional(),
    ended: z.boolean().optional(),
    sourceUrl: z.string().trim().url().max(500).startsWith('https://').optional(),
  })
  .refine((v) => {
    const set = [v.latitude, v.longitude, v.radiusKm].filter((x) => x !== undefined).length;
    return set === 0 || set === 3;
  })
  .refine((v) => v.latitude !== undefined || v.province !== undefined || v.district !== undefined);

export interface IngestResult {
  upserted: number;
  rejected: number;
}

/** Fetches from [adapter] and upserts every valid alert by (source, externalId). */
export async function ingestFromAdapter(adapter: DisasterSourceAdapter): Promise<IngestResult> {
  const items = await adapter.fetchAlerts();
  let upserted = 0;
  let rejected = 0;
  for (const item of items) {
    const parsed = normalizedAlertSchema.safeParse(item);
    if (!parsed.success) {
      rejected++;
      continue;
    }
    const a = parsed.data;
    await pool.query(
      `INSERT INTO emergency_alerts
         (source_type, source_name, external_id, category, severity, status, title, body, instructions,
          latitude, longitude, radius_km, province, district, issued_at, expires_at, resolved_at, source_url,
          retrieved_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, COALESCE($15::timestamptz, now()), $16,
               CASE WHEN $17::boolean THEN now() ELSE NULL END, $18, now())
       ON CONFLICT (source_name, external_id) WHERE external_id IS NOT NULL DO UPDATE SET
         category = EXCLUDED.category, severity = EXCLUDED.severity, status = EXCLUDED.status,
         title = EXCLUDED.title, body = EXCLUDED.body, instructions = EXCLUDED.instructions,
         latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude, radius_km = EXCLUDED.radius_km,
         province = EXCLUDED.province, district = EXCLUDED.district, expires_at = EXCLUDED.expires_at,
         resolved_at = COALESCE(emergency_alerts.resolved_at, EXCLUDED.resolved_at),
         source_url = EXCLUDED.source_url, retrieved_at = EXCLUDED.retrieved_at`,
      [
        adapter.sourceType,
        adapter.sourceName,
        a.externalId,
        a.category,
        a.severity,
        a.ended ? 'resolved' : 'active',
        a.title,
        a.body,
        a.instructions ?? null,
        a.latitude ?? null,
        a.longitude ?? null,
        a.radiusKm ?? null,
        a.province ?? null,
        a.district ?? null,
        a.issuedAt ?? null,
        a.expiresAt ?? null,
        a.ended === true,
        a.sourceUrl ?? null,
      ],
    );
    upserted++;
  }
  if (rejected > 0) logger.warn({ source: adapter.sourceName, rejected }, 'Disaster source returned invalid alerts');
  return { upserted, rejected };
}

/** Verified adapters in use. Empty until a source is verified. */
export const registeredAdapters: DisasterSourceAdapter[] = [];

export interface DisasterSourceStatus {
  registered: Array<{
    sourceName: string;
    sourceType: DisasterSourceAdapter['sourceType'];
    homepageUrl: string | null;
    terms: { status: 'verified' | 'pending' | 'unknown'; note: string | null };
  }>;
  /**
   * Nothing runs the adapters on a schedule yet, so even a registered
   * adapter only ingests when ingestFromAdapter is called.
   */
  scheduledIngestion: false;
  /** External sources that have written alerts into the database, from the alerts themselves. */
  observed: Array<{
    sourceName: string;
    sourceType: string;
    lastRetrievedAt: string | null;
    activeAlerts: number;
    totalAlerts: number;
  }>;
}

export async function getDisasterSourceStatus(): Promise<DisasterSourceStatus> {
  const { rows } = await pool.query<{
    source_name: string;
    source_type: string;
    last_retrieved: Date | null;
    active: number;
    total: number;
  }>(
    `SELECT source_name, source_type, max(retrieved_at) AS last_retrieved,
            count(*) FILTER (WHERE status = 'active')::int AS active, count(*)::int AS total
     FROM emergency_alerts
     WHERE external_id IS NOT NULL
     GROUP BY source_name, source_type
     ORDER BY max(retrieved_at) DESC NULLS LAST
     LIMIT 100`,
  );
  return {
    registered: registeredAdapters.map((a) => ({
      sourceName: a.sourceName,
      sourceType: a.sourceType,
      homepageUrl: a.homepageUrl ?? null,
      terms: { status: a.terms?.status ?? 'unknown', note: a.terms?.note ?? null },
    })),
    scheduledIngestion: false,
    observed: rows.map((r) => ({
      sourceName: r.source_name,
      sourceType: r.source_type,
      lastRetrievedAt: r.last_retrieved?.toISOString() ?? null,
      activeAlerts: r.active,
      totalAlerts: r.total,
    })),
  };
}
