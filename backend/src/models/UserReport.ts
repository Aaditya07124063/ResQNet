export interface DbUserReportRow {
  id: string;
  reporter_user_id: string;
  reported_user_id: string;
  reason: string;
  description: string | null;
  status: 'open' | 'dismissed' | 'actioned';
  resolution: string | null;
  resolved_by_employee_id: string | null;
  resolved_at: Date | null;
  created_at: Date;
}

/** Deliberately minimal — never echoes the reporter's own id back (the
 * caller already knows it), and never reveals moderation-internal state
 * (review-case/threshold side effects) through this shape. */
export interface UserReport {
  id: string;
  reportedUserId: string;
  reason: string;
  description: string | null;
  status: DbUserReportRow['status'];
  createdAt: string;
}

export function toUserReport(row: DbUserReportRow): UserReport {
  return {
    id: row.id,
    reportedUserId: row.reported_user_id,
    reason: row.reason,
    description: row.description,
    status: row.status,
    createdAt: row.created_at.toISOString(),
  };
}

/** Phase 16 — the employee-facing shape of a report, used only behind the
 * moderation RBAC permission. Unlike `toUserReport` (returned to the
 * reporting user themselves), this DOES include `reporterUserId` — an
 * employee reviewing a case needs to know who filed each report (e.g. to
 * spot a pattern of bad-faith reporting), which is a different audience
 * and trust level than the reporting/reported-on consumer users. */
export interface ModerationReportView {
  id: string;
  reporterUserId: string;
  reportedUserId: string;
  reason: string;
  description: string | null;
  status: DbUserReportRow['status'];
  resolution: string | null;
  resolvedByEmployeeId: string | null;
  resolvedAt: string | null;
  createdAt: string;
}

export function toModerationReportView(row: DbUserReportRow): ModerationReportView {
  return {
    id: row.id,
    reporterUserId: row.reporter_user_id,
    reportedUserId: row.reported_user_id,
    reason: row.reason,
    description: row.description,
    status: row.status,
    resolution: row.resolution,
    resolvedByEmployeeId: row.resolved_by_employee_id,
    resolvedAt: row.resolved_at ? row.resolved_at.toISOString() : null,
    createdAt: row.created_at.toISOString(),
  };
}
