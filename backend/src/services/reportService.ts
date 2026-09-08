import type { PoolClient } from 'pg';
import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import { toUserReport, type DbUserReportRow, type UserReport } from '../models/UserReport';

export interface CreateReportInput {
  reportedUserId: string;
  reason: string;
  description: string | null;
}

interface PgError {
  code?: string;
}

function pgErrorCode(err: unknown): string | undefined {
  return typeof err === 'object' && err !== null ? (err as PgError).code : undefined;
}

/**
 * Creates a report. `reporterUserId` must come from the authenticated
 * session (req.authUser.id) — callers enforce that at the route layer,
 * never from a client-supplied field.
 *
 * The review-case threshold check (see maybeOpenReviewCase) runs as a
 * separate, best-effort step AFTER the report is safely recorded: a
 * failure there must never roll back or fail the user's own successful
 * report submission.
 */
export async function createReport(reporterUserId: string, input: CreateReportInput): Promise<UserReport> {
  if (reporterUserId === input.reportedUserId) {
    throw HttpError.badRequest('You cannot report yourself');
  }

  let reportRow: DbUserReportRow;
  try {
    const { rows } = await pool.query<DbUserReportRow>(
      `INSERT INTO user_reports (reporter_user_id, reported_user_id, reason, description)
       VALUES ($1, $2, $3, $4)
       RETURNING *`,
      [reporterUserId, input.reportedUserId, input.reason, input.description],
    );
    reportRow = rows[0]!;
  } catch (err) {
    const code = pgErrorCode(err);
    if (code === '23505') {
      // uq_user_reports_open_pair — reporter already has an open report
      // against this same target.
      throw HttpError.conflict('You already have an open report against this user');
    }
    if (code === '23503') {
      // FK violation on reported_user_id — target does not exist.
      throw HttpError.badRequest('Report target does not exist');
    }
    if (code === '23514') {
      // chk_user_reports_not_self — defense in depth; the check above
      // already covers this in the normal path.
      throw HttpError.badRequest('You cannot report yourself');
    }
    throw err;
  }

  try {
    await maybeOpenReviewCase(input.reportedUserId);
  } catch (err) {
    logger.error(
      { err, targetUserId: input.reportedUserId },
      'Report threshold/review-case evaluation failed — the report itself was still recorded',
    );
  }

  return toUserReport(reportRow);
}

/**
 * Opens a review_case (and flips the target's account_status to
 * 'review_required') once their open-report count crosses an
 * admin-configured threshold — but ONLY if that threshold is actually
 * configured in admin_settings. There is no Phase 15 admin API yet to set
 * report_threshold/report_window_days, so in practice this currently
 * never fires; that is the correct, schema-faithful behavior (never
 * invent a fallback threshold — see docs/AUDIT.md's original "do not
 * hard-code X = 5" instruction).
 */
async function maybeOpenReviewCase(targetUserId: string): Promise<void> {
  await withTransaction(async (client: PoolClient) => {
    const { rows: settingRows } = await client.query<{ key: string; value: unknown }>(
      `SELECT key, value FROM admin_settings WHERE key IN ('report_threshold', 'report_window_days')`,
    );
    const settings = new Map(settingRows.map((r) => [r.key, r.value]));
    const threshold = settings.get('report_threshold');
    if (typeof threshold !== 'number' || threshold <= 0) {
      return;
    }

    const windowDays = settings.get('report_window_days');
    const hasWindow = typeof windowDays === 'number' && windowDays > 0;

    const { rows: countRows } = await client.query<{ count: string }>(
      hasWindow
        ? `SELECT count(*)::text AS count FROM user_reports
           WHERE reported_user_id = $1 AND status = 'open' AND created_at >= now() - ($2 || ' days')::interval`
        : `SELECT count(*)::text AS count FROM user_reports WHERE reported_user_id = $1 AND status = 'open'`,
      hasWindow ? [targetUserId, windowDays] : [targetUserId],
    );
    const openReportCount = Number(countRows[0]?.count ?? '0');
    if (openReportCount < threshold) return;

    const { rows: existingCase } = await client.query(
      `SELECT id FROM review_cases WHERE target_user_id = $1 AND status = 'open' LIMIT 1`,
      [targetUserId],
    );
    if (existingCase[0]) return; // already under review — don't open a duplicate case

    await client.query(
      `INSERT INTO review_cases (target_user_id, trigger_reason, report_count_at_open)
       VALUES ($1, 'report_threshold', $2)`,
      [targetUserId, openReportCount],
    );
    // Only ever promotes an ACTIVE account into review — never overrides
    // an already-suspended/deleted/under-review status.
    await client.query(
      `UPDATE users SET account_status = 'review_required' WHERE id = $1 AND account_status = 'active'`,
      [targetUserId],
    );
    logger.info(
      { targetUserId, openReportCount, threshold },
      'Report threshold crossed — review case opened',
    );
  });
}
