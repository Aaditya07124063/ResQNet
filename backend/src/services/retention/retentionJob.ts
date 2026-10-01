import type { PoolClient } from 'pg';
import { pool } from '../../database/pool';
import { logger } from '../../utils/logger';
import { recordAuditEvent } from '../auditLogService';
import { cutoff, retentionPolicyFromEnv, type RetentionPolicy } from './retentionPolicy';

// Automated retention: redacts, de-identifies or deletes records that are
// past their retention period (docs/PRIVACY_AND_RETENTION.md).
//
// Safety properties:
// - One run at a time across all API instances (pg_try_advisory_lock).
// - Each batch is one short transaction over at most `batchSize` rows,
//   selected with FOR UPDATE SKIP LOCKED and lock/statement timeouts, so it
//   never waits on or blocks live traffic for long.
// - The eligibility condition is checked again inside the action itself.
// - Open incidents are never touched: SOS rules require a responder closure
//   (ops_closed_at) and no retention hold.
// - A failing category is rolled back and reported; other categories still
//   run; the next run starts again safely (everything is idempotent).
// - Only counts are logged or audited — never record contents.

export interface RetentionCategory {
  name: string;
  /** What happens to eligible rows (for the report and docs). */
  effect: 'redact' | 'deidentify' | 'delete' | 'revoke';
  table: string;
  key: string;
  keyType: 'uuid' | 'bigint';
  /** Days after which a row is eligible; undefined disables the category. */
  days: (policy: RetentionPolicy) => number | undefined;
  /** Eligibility SQL. `:cutoff` and `:now` are bound per statement. */
  where: string;
  /** UPDATE/DELETE on the batch; must end with `RETURNING <key>`. `:keys` is the batch. */
  action: string;
  /** Statements run after the action on the keys it returned (`:keys`), same transaction. */
  followUps?: string[];
}

const SOS_CLOSED = "ops_status IN ('resolved', 'stood_down') AND ops_closed_at IS NOT NULL AND retention_hold_at IS NULL";

export const RETENTION_CATEGORIES: RetentionCategory[] = [
  {
    name: 'sos_sensitive_redaction',
    effect: 'redact',
    table: 'sos_events',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.sosSensitiveDays,
    where: `${SOS_CLOSED} AND sensitive_redacted_at IS NULL AND ops_closed_at <= :cutoff`,
    action: `UPDATE sos_events SET message = NULL, latitude = NULL, longitude = NULL, location_accuracy_m = NULL,
               origin_envelope_raw = NULL, origin_signature = NULL, sensitive_redacted_at = :now
             WHERE id = ANY(:keys) AND ${SOS_CLOSED} AND sensitive_redacted_at IS NULL AND ops_closed_at <= :cutoff
             RETURNING id`,
    followUps: [
      `UPDATE sos_incident_updates SET note = NULL, note_redacted_at = :now
        WHERE sos_event_id = ANY(:keys) AND note IS NOT NULL`,
      // Delivery log: contact phone numbers and nearby distances.
      'DELETE FROM sos_recipients WHERE sos_event_id = ANY(:keys)',
      'DELETE FROM locations WHERE sos_event_id = ANY(:keys)',
    ],
  },
  {
    name: 'sos_deidentify',
    effect: 'deidentify',
    table: 'sos_events',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.sosDeidentifyDays,
    where: `${SOS_CLOSED} AND sensitive_redacted_at IS NOT NULL AND deidentified_at IS NULL AND ops_closed_at <= :cutoff`,
    action: `UPDATE sos_events SET user_id = NULL, origin_claimed_user_id = NULL, origin_device_id = NULL,
               origin_key_id = NULL, deidentified_at = :now
             WHERE id = ANY(:keys) AND ${SOS_CLOSED} AND sensitive_redacted_at IS NOT NULL AND deidentified_at IS NULL
               AND ops_closed_at <= :cutoff
             RETURNING id`,
  },
  {
    name: 'sos_record_delete',
    effect: 'delete',
    table: 'sos_events',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.sosRecordDeleteDays,
    where: `${SOS_CLOSED} AND deidentified_at IS NOT NULL AND ops_closed_at <= :cutoff`,
    // Timeline, delivery rows and legacy location rows go with it (their
    // foreign keys cascade from sos_events); incidents.origin_sos_event_id
    // is set to NULL.
    action: `DELETE FROM sos_events
             WHERE id = ANY(:keys) AND ${SOS_CLOSED} AND deidentified_at IS NOT NULL AND ops_closed_at <= :cutoff
             RETURNING id`,
  },
  {
    name: 'chat_location_messages',
    effect: 'delete',
    table: 'messages',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.chatLocationDays,
    where: `message_type = 'location' AND server_received_at <= :cutoff`,
    action: `DELETE FROM messages WHERE id = ANY(:keys) AND message_type = 'location' AND server_received_at <= :cutoff
             RETURNING id`,
  },
  {
    name: 'deleted_messages',
    effect: 'delete',
    table: 'messages',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.deletedMessageDays,
    where: 'deleted_at IS NOT NULL AND deleted_at <= :cutoff',
    action: `DELETE FROM messages WHERE id = ANY(:keys) AND deleted_at IS NOT NULL AND deleted_at <= :cutoff RETURNING id`,
  },
  {
    name: 'stale_nearby_locations',
    effect: 'delete',
    table: 'nearby_alert_locations',
    key: 'user_id',
    keyType: 'uuid',
    days: (p) => p.nearbyLocationDays,
    where: 'updated_at <= :cutoff',
    action: `DELETE FROM nearby_alert_locations WHERE user_id = ANY(:keys) AND updated_at <= :cutoff RETURNING user_id`,
  },
  {
    name: 'seismic_reports',
    effect: 'delete',
    table: 'seismic_reports',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.seismicReportDays,
    where: 'reported_at <= :cutoff',
    action: 'DELETE FROM seismic_reports WHERE id = ANY(:keys) AND reported_at <= :cutoff RETURNING id',
  },
  {
    name: 'otp_attempts',
    effect: 'delete',
    table: 'verification_attempts',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.otpDays,
    // Codes expire in minutes; the resend cooldown reads only the last minute.
    where: 'created_at <= :cutoff AND expires_at < :now',
    action: `DELETE FROM verification_attempts WHERE id = ANY(:keys) AND created_at <= :cutoff AND expires_at < :now
             RETURNING id`,
  },
  {
    name: 'user_sessions',
    effect: 'delete',
    table: 'sessions',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.sessionDays,
    // Only sessions that ended (revoked, or expired) at least :cutoff ago; a valid session never matches.
    where: '(revoked_at IS NOT NULL AND revoked_at <= :cutoff) OR (revoked_at IS NULL AND expires_at <= :cutoff)',
    action: `DELETE FROM sessions WHERE id = ANY(:keys)
               AND ((revoked_at IS NOT NULL AND revoked_at <= :cutoff) OR (revoked_at IS NULL AND expires_at <= :cutoff))
             RETURNING id`,
  },
  {
    name: 'employee_sessions',
    effect: 'delete',
    table: 'employee_sessions',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.sessionDays,
    where: '(revoked_at IS NOT NULL AND revoked_at <= :cutoff) OR (revoked_at IS NULL AND expires_at <= :cutoff)',
    action: `DELETE FROM employee_sessions WHERE id = ANY(:keys)
               AND ((revoked_at IS NOT NULL AND revoked_at <= :cutoff) OR (revoked_at IS NULL AND expires_at <= :cutoff))
             RETURNING id`,
  },
  {
    name: 'disabled_employee_sessions',
    effect: 'revoke',
    table: 'employee_sessions',
    key: 'id',
    keyType: 'uuid',
    // Safety net: a disabled employee keeps no usable refresh token.
    days: () => 0,
    where: `revoked_at IS NULL AND employee_id IN (SELECT id FROM employees WHERE status = 'disabled')`,
    action: `UPDATE employee_sessions SET revoked_at = :now
             WHERE id = ANY(:keys) AND revoked_at IS NULL
               AND employee_id IN (SELECT id FROM employees WHERE status = 'disabled')
             RETURNING id`,
  },
  {
    name: 'stale_devices',
    effect: 'delete',
    table: 'devices',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.staleDeviceDays,
    where: 'COALESCE(last_seen_at, created_at) <= :cutoff',
    action: 'DELETE FROM devices WHERE id = ANY(:keys) AND COALESCE(last_seen_at, created_at) <= :cutoff RETURNING id',
  },
  {
    name: 'revoked_device_keys',
    effect: 'delete',
    table: 'device_keys',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.revokedDeviceKeyDays,
    where: 'revoked_at IS NOT NULL AND revoked_at <= :cutoff',
    action: 'DELETE FROM device_keys WHERE id = ANY(:keys) AND revoked_at IS NOT NULL AND revoked_at <= :cutoff RETURNING id',
  },
  {
    name: 'audit_ip_addresses',
    effect: 'redact',
    table: 'audit_logs',
    key: 'id',
    keyType: 'bigint',
    days: (p) => p.auditIpDays,
    where: 'ip_address IS NOT NULL AND created_at <= :cutoff',
    action: `UPDATE audit_logs SET ip_address = NULL WHERE id = ANY(:keys) AND ip_address IS NOT NULL AND created_at <= :cutoff
             RETURNING id`,
  },
  {
    name: 'audit_logs',
    effect: 'delete',
    table: 'audit_logs',
    key: 'id',
    keyType: 'bigint',
    days: (p) => p.auditLogDays,
    where: 'created_at <= :cutoff',
    action: 'DELETE FROM audit_logs WHERE id = ANY(:keys) AND created_at <= :cutoff RETURNING id',
  },
  {
    name: 'closed_alerts',
    effect: 'delete',
    table: 'emergency_alerts',
    key: 'id',
    keyType: 'uuid',
    days: (p) => p.closedAlertDays,
    // Resolved/cancelled, or active but long expired. A current alert never matches.
    where: `(status <> 'active' AND updated_at <= :cutoff) OR (status = 'active' AND expires_at IS NOT NULL AND expires_at <= :cutoff)`,
    action: `DELETE FROM emergency_alerts WHERE id = ANY(:keys)
               AND ((status <> 'active' AND updated_at <= :cutoff) OR (status = 'active' AND expires_at IS NOT NULL AND expires_at <= :cutoff))
             RETURNING id`,
  },
];

export interface CategoryReport {
  category: string;
  effect: RetentionCategory['effect'];
  /** Rows selected as candidates (dry run: rows eligible). */
  examined: number;
  /** Rows actually changed or deleted (0 in a dry run). */
  affected: number;
  /** More eligible rows remain after hitting the batch limit. */
  more: boolean;
  ok: boolean;
  skipped?: 'disabled';
  /** PostgreSQL error code only — never the message or detail (they can quote row values). */
  errorCode?: string;
  durationMs: number;
}

export interface RetentionRunReport {
  startedAt: string;
  finishedAt: string;
  dryRun: boolean;
  /** Another run held the lock; nothing was done. */
  skippedLocked: boolean;
  ok: boolean;
  categories: CategoryReport[];
}

export interface RetentionRunOptions {
  now?: Date;
  dryRun?: boolean;
  policy?: RetentionPolicy;
  categories?: RetentionCategory[];
  /** Skip the audit entry (tests). */
  audit?: boolean;
}

const LOCK_KEY = 'resqnet.retention';

type Params = Record<string, { value: unknown; cast: string }>;

/**
 * Replaces each `:name` used in [sql] with a typed positional parameter.
 * Only the parameters a statement actually uses are sent (PostgreSQL
 * rejects untyped, unreferenced parameters).
 */
export function prepare(sql: string, params: Params): { text: string; values: unknown[] } {
  const values: unknown[] = [];
  const text = sql.replace(/(?<!:):([a-z]+)\b/g, (match, name: string) => {
    const p = params[name];
    if (!p) return match;
    values.push(p.value);
    return `$${values.length}::${p.cast}`;
  });
  return { text, values };
}

async function runCategory(
  client: PoolClient,
  category: RetentionCategory,
  policy: RetentionPolicy,
  now: Date,
  dryRun: boolean,
): Promise<CategoryReport> {
  const started = Date.now();
  const report: CategoryReport = { category: category.name, effect: category.effect, examined: 0, affected: 0, more: false, ok: true, durationMs: 0 };
  const days = category.days(policy);
  if (days === undefined) {
    return { ...report, skipped: 'disabled', durationMs: Date.now() - started };
  }
  const limitTo = cutoff(now, days);
  const keyCast = category.keyType === 'uuid' ? 'uuid[]' : 'bigint[]';
  const base: Params = { cutoff: { value: limitTo, cast: 'timestamptz' }, now: { value: now, cast: 'timestamptz' } };

  if (dryRun) {
    const q = prepare(`SELECT count(*)::int AS n FROM ${category.table} WHERE (${category.where})`, base);
    const { rows } = await client.query<{ n: number }>(q.text, q.values);
    return { ...report, examined: rows[0]!.n, durationMs: Date.now() - started };
  }

  const select = prepare(
    `SELECT ${category.key}::text AS k FROM ${category.table} WHERE (${category.where})
     ORDER BY ${category.key} LIMIT :limit FOR UPDATE SKIP LOCKED`,
    { ...base, limit: { value: policy.batchSize, cast: 'int' } },
  );
  const withKeys = (sql: string, keys: string[]) => prepare(sql, { ...base, keys: { value: keys, cast: keyCast } });

  for (let batch = 0; batch < policy.maxBatchesPerCategory; batch++) {
    await client.query('BEGIN');
    try {
      await client.query("SET LOCAL lock_timeout = '5s'");
      await client.query("SET LOCAL statement_timeout = '60s'");
      const { rows } = await client.query<{ k: string }>(select.text, select.values);
      if (rows.length === 0) {
        await client.query('COMMIT');
        break;
      }
      const keys = rows.map((r) => r.k);
      const action = withKeys(category.action, keys);
      const done = await client.query<Record<string, unknown>>(action.text, action.values);
      const affectedKeys = done.rows.map((r) => String(Object.values(r)[0]));
      for (const sql of category.followUps ?? []) {
        if (affectedKeys.length === 0) continue;
        const followUp = withKeys(sql, affectedKeys);
        await client.query(followUp.text, followUp.values);
      }
      await client.query('COMMIT');
      report.examined += keys.length;
      report.affected += affectedKeys.length;
      if (rows.length < policy.batchSize) break;
      if (batch === policy.maxBatchesPerCategory - 1) report.more = true;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => undefined);
      report.ok = false;
      report.errorCode = (err as { code?: string }).code ?? 'UNKNOWN';
      break;
    }
  }
  report.durationMs = Date.now() - started;
  return report;
}

/**
 * Runs every retention category once. Returns a report; never throws for a
 * category failure (the report says ok: false). Throws only if it cannot
 * get a database connection at all.
 */
export async function runRetention(options: RetentionRunOptions = {}): Promise<RetentionRunReport> {
  const now = options.now ?? new Date();
  const policy = options.policy ?? retentionPolicyFromEnv();
  const categories = options.categories ?? RETENTION_CATEGORIES;
  const dryRun = options.dryRun ?? false;
  const startedAt = new Date().toISOString();
  const client = await pool.connect();
  const reports: CategoryReport[] = [];
  let locked = false;
  try {
    const lock = await client.query<{ ok: boolean }>('SELECT pg_try_advisory_lock(hashtext($1)) AS ok', [LOCK_KEY]);
    locked = lock.rows[0]?.ok === true;
    if (!locked) {
      logger.warn({ job: 'retention' }, 'Retention run skipped: another run holds the lock');
      return { startedAt, finishedAt: new Date().toISOString(), dryRun, skippedLocked: true, ok: true, categories: [] };
    }
    for (const category of categories) {
      const report = await runCategory(client, category, policy, now, dryRun);
      reports.push(report);
      logger[report.ok ? 'info' : 'error'](
        {
          job: 'retention',
          category: report.category,
          effect: report.effect,
          examined: report.examined,
          affected: report.affected,
          more: report.more,
          ok: report.ok,
          errorCode: report.errorCode,
          skipped: report.skipped,
          durationMs: report.durationMs,
          dryRun,
        },
        'Retention category finished',
      );
    }
  } finally {
    if (locked) await client.query('SELECT pg_advisory_unlock(hashtext($1))', [LOCK_KEY]).catch(() => undefined);
    client.release();
  }
  const result: RetentionRunReport = {
    startedAt,
    finishedAt: new Date().toISOString(),
    dryRun,
    skippedLocked: false,
    ok: reports.every((r) => r.ok),
    categories: reports,
  };
  if (options.audit !== false) {
    await recordAuditEvent({
      action: dryRun ? 'retention.dry_run' : 'retention.run',
      resourceType: 'system',
      outcome: result.ok ? 'success' : 'error',
      metadata: {
        categories: Object.fromEntries(
          reports.map((r) => [r.category, { examined: r.examined, affected: r.affected, more: r.more, ok: r.ok, errorCode: r.errorCode ?? null }]),
        ),
      },
    });
  }
  return result;
}
