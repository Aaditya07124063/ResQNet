export interface DbReviewCaseRow {
  id: string;
  target_user_id: string;
  status: 'open' | 'closed';
  trigger_reason: string;
  report_count_at_open: number;
  opened_at: Date;
  closed_at: Date | null;
  closed_by_employee_id: string | null;
}

export interface ReviewCase {
  id: string;
  targetUserId: string;
  status: DbReviewCaseRow['status'];
  triggerReason: string;
  reportCountAtOpen: number;
  openedAt: string;
  closedAt: string | null;
  closedByEmployeeId: string | null;
}

export function toReviewCase(row: DbReviewCaseRow): ReviewCase {
  return {
    id: row.id,
    targetUserId: row.target_user_id,
    status: row.status,
    triggerReason: row.trigger_reason,
    reportCountAtOpen: row.report_count_at_open,
    openedAt: row.opened_at.toISOString(),
    closedAt: row.closed_at ? row.closed_at.toISOString() : null,
    closedByEmployeeId: row.closed_by_employee_id,
  };
}
