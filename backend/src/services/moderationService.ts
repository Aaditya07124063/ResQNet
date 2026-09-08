import type { PoolClient } from 'pg';
import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { toReviewCase, type DbReviewCaseRow, type ReviewCase } from '../models/ReviewCase';
import { toModerationAction, type DbModerationActionRow, type ModerationAction } from '../models/ModerationAction';
import { toModerationReportView, type DbUserReportRow, type ModerationReportView } from '../models/UserReport';
import type { TakeModerationActionInput } from '../validation/moderationSchemas';

/**
 * Phase 16 — the review queue and moderation-action workflow built on top
 * of Phase 14's reporting (user_reports/review_cases, already live) and
 * Phase 15's employee RBAC. Nothing here creates a review_case — that
 * already happens automatically in reportService.ts's maybeOpenReviewCase
 * once an admin-configured report_threshold is crossed (Phase 15 gave
 * that logic somewhere to actually be configured from). This service only
 * lets an authorized employee act on cases that already exist.
 */

export async function listReviewCases(status?: 'open' | 'closed'): Promise<ReviewCase[]> {
  const { rows } = status
    ? await pool.query<DbReviewCaseRow>(
        'SELECT * FROM review_cases WHERE status = $1 ORDER BY opened_at DESC',
        [status],
      )
    : await pool.query<DbReviewCaseRow>('SELECT * FROM review_cases ORDER BY opened_at DESC');
  return rows.map(toReviewCase);
}

/**
 * A review case plus the reports behind it. There is no `review_case_id`
 * column on `user_reports` (the schema links them only by
 * `target_user_id` = `reported_user_id`, snapshotting a count rather than
 * a specific report-id list at open time — see review_cases.report_count_at_open)
 * — so "the reports for this case" is necessarily every report ever
 * filed against this case's target, not a fixed set captured at open
 * time. That is the correct, schema-faithful reading, not an assumption:
 * a case being actively reviewed should surface ALL reporting history
 * against that user, including anything filed after the case opened.
 */
export async function getReviewCaseWithReports(
  id: string,
): Promise<{ reviewCase: ReviewCase; reports: ModerationReportView[] } | null> {
  const { rows } = await pool.query<DbReviewCaseRow>('SELECT * FROM review_cases WHERE id = $1', [id]);
  const row = rows[0];
  if (!row) return null;

  const { rows: reportRows } = await pool.query<DbUserReportRow>(
    'SELECT * FROM user_reports WHERE reported_user_id = $1 ORDER BY created_at DESC',
    [row.target_user_id],
  );

  return { reviewCase: toReviewCase(row), reports: reportRows.map(toModerationReportView) };
}

const TERMINAL_ACCOUNT_STATUS_BY_ACTION: Partial<Record<TakeModerationActionInput['actionType'], 'suspended' | 'deleted'>> = {
  suspend_temporary: 'suspended',
  suspend_permanent: 'suspended',
  delete: 'deleted',
};

/**
 * Takes a moderation action against a review case.
 *
 * `escalate` is the one action type that does NOT close the case, resolve
 * the underlying reports, or change account_status — its entire meaning
 * is "not resolving this myself" (no reassignment/routing/notification is
 * specified anywhere, so none is built; it is recorded as an audited
 * action and nothing more). Every other action type is a real
 * disposition: it closes the case, resolves every currently-OPEN report
 * against the target (status='dismissed' for `dismiss`, else 'actioned'
 * — 'dismiss' is precisely how a case is closed with no further action),
 * and — only for the two suspend variants and `delete` — updates
 * `users.account_status` to the identically-named value the schema
 * already defines (nothing else in this codebase ever sets 'suspended'
 * or 'deleted'; requireAuth/wsAuth already check for and block both,
 * confirming the mapping is the schema's own clear intent, not a guess).
 * `delete` is a SOFT state marker (account_status='deleted'), exactly
 * like the 'deleted' the account_status CHECK constraint already
 * enumerates — never a physical row DELETE (that would CASCADE-destroy
 * the user's trusted contacts/SOS history/etc., which nothing in this
 * project's spec asks for).
 *
 * Runs as one transaction, `SELECT ... FOR UPDATE` on the case row, so a
 * concurrent duplicate action against the same case cannot both succeed —
 * the second one sees the case already closed and is rejected.
 */
export async function takeModerationAction(
  reviewCaseId: string,
  employeeId: string,
  input: TakeModerationActionInput,
): Promise<{ action: ModerationAction; reviewCase: ReviewCase }> {
  return withTransaction(async (client) => {
    const { rows: caseRows } = await client.query<DbReviewCaseRow>(
      'SELECT * FROM review_cases WHERE id = $1 FOR UPDATE',
      [reviewCaseId],
    );
    const caseRow = caseRows[0];
    if (!caseRow) {
      throw HttpError.notFound('Review case not found');
    }
    if (caseRow.status !== 'open') {
      throw HttpError.conflict('This review case is already closed');
    }

    const { rows: actionRows } = await client.query<DbModerationActionRow>(
      `INSERT INTO moderation_actions (target_user_id, review_case_id, action_type, performed_by_employee_id, reason)
       VALUES ($1, $2, $3, $4, $5)
       RETURNING *`,
      [caseRow.target_user_id, reviewCaseId, input.actionType, employeeId, input.reason],
    );
    const action = toModerationAction(actionRows[0]!);

    let updatedCaseRow = caseRow;
    if (input.actionType !== 'escalate') {
      updatedCaseRow = await closeCaseAndResolveReports(client, caseRow, employeeId, input);

      const newAccountStatus = TERMINAL_ACCOUNT_STATUS_BY_ACTION[input.actionType];
      if (newAccountStatus) {
        // Phase 19 security audit fix: never let a `suspend_*` action on a
        // LATER, unrelated review case downgrade an account that some
        // earlier case already soft-deleted — 'deleted' is the strictest
        // terminal state this schema has, and nothing should un-delete it
        // by accident via a lesser action. Mirrors the same
        // never-downgrade guard reportService.ts's maybeOpenReviewCase
        // already uses (`AND account_status = 'active'`).
        await client.query(
          "UPDATE users SET account_status = $1 WHERE id = $2 AND account_status != 'deleted'",
          [newAccountStatus, caseRow.target_user_id],
        );
      }
    }

    return { action, reviewCase: toReviewCase(updatedCaseRow) };
  });
}

async function closeCaseAndResolveReports(
  client: PoolClient,
  caseRow: DbReviewCaseRow,
  employeeId: string,
  input: TakeModerationActionInput,
): Promise<DbReviewCaseRow> {
  const { rows } = await client.query<DbReviewCaseRow>(
    `UPDATE review_cases SET status = 'closed', closed_at = now(), closed_by_employee_id = $1
     WHERE id = $2
     RETURNING *`,
    [employeeId, caseRow.id],
  );

  const reportStatus = input.actionType === 'dismiss' ? 'dismissed' : 'actioned';
  await client.query(
    `UPDATE user_reports
     SET status = $1, resolution = $2, resolved_by_employee_id = $3, resolved_at = now()
     WHERE reported_user_id = $4 AND status = 'open'`,
    [reportStatus, input.reason, employeeId, caseRow.target_user_id],
  );

  return rows[0]!;
}
