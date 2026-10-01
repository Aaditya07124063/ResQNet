import { env } from '../../config/env';

// The retention periods, in one place. Every default is a ResQNet
// operational policy decision (docs/PRIVACY_AND_RETENTION.md), not a legal
// requirement; each can be changed with its RETENTION_* variable.

export interface RetentionPolicy {
  /** Closed incident → message, exact location, raw envelope, delivery phones, note text removed. */
  sosSensitiveDays: number;
  /** Closed incident → link to the reporter's account and device removed. */
  sosDeidentifyDays: number;
  /** Closed + de-identified incident → row deleted. Undefined: kept. */
  sosRecordDeleteDays: number | undefined;
  chatLocationDays: number;
  deletedMessageDays: number;
  nearbyLocationDays: number;
  seismicReportDays: number;
  otpDays: number;
  /** After a session expired or was revoked. */
  sessionDays: number;
  staleDeviceDays: number;
  revokedDeviceKeyDays: number;
  auditIpDays: number;
  auditLogDays: number;
  closedAlertDays: number;
  batchSize: number;
  maxBatchesPerCategory: number;
}

export function retentionPolicyFromEnv(): RetentionPolicy {
  return {
    sosSensitiveDays: env.RETENTION_SOS_SENSITIVE_DAYS,
    sosDeidentifyDays: Math.max(env.RETENTION_SOS_DEIDENTIFY_DAYS, env.RETENTION_SOS_SENSITIVE_DAYS),
    sosRecordDeleteDays:
      env.RETENTION_SOS_RECORD_DELETE_DAYS === undefined
        ? undefined
        : Math.max(env.RETENTION_SOS_RECORD_DELETE_DAYS, env.RETENTION_SOS_DEIDENTIFY_DAYS),
    chatLocationDays: env.RETENTION_CHAT_LOCATION_DAYS,
    deletedMessageDays: env.RETENTION_DELETED_MESSAGE_DAYS,
    nearbyLocationDays: env.RETENTION_NEARBY_LOCATION_DAYS,
    seismicReportDays: env.RETENTION_SEISMIC_REPORT_DAYS,
    otpDays: env.RETENTION_OTP_DAYS,
    sessionDays: env.RETENTION_SESSION_DAYS,
    staleDeviceDays: env.RETENTION_STALE_DEVICE_DAYS,
    revokedDeviceKeyDays: env.RETENTION_REVOKED_DEVICE_KEY_DAYS,
    auditIpDays: env.RETENTION_AUDIT_IP_DAYS,
    auditLogDays: env.RETENTION_AUDIT_LOG_DAYS,
    closedAlertDays: env.RETENTION_CLOSED_ALERT_DAYS,
    batchSize: env.RETENTION_BATCH_SIZE,
    maxBatchesPerCategory: env.RETENTION_MAX_BATCHES,
  };
}

const DAY_MS = 86_400_000;

/** Records whose relevant time is at or before this instant are eligible. */
export function cutoff(now: Date, days: number): Date {
  return new Date(now.getTime() - days * DAY_MS);
}

/** True when a closed incident's sensitive fields are past retention (and not on hold). */
export function isSosSensitiveExpired(
  row: { ops_closed_at: Date | null; retention_hold_at: Date | null },
  now: Date,
  policy: Pick<RetentionPolicy, 'sosSensitiveDays'>,
): boolean {
  return (
    row.ops_closed_at !== null &&
    row.retention_hold_at === null &&
    row.ops_closed_at.getTime() <= cutoff(now, policy.sosSensitiveDays).getTime()
  );
}
