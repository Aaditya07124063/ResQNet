export interface DbModerationActionRow {
  id: string;
  target_user_id: string;
  review_case_id: string | null;
  action_type: 'dismiss' | 'warn' | 'suspend_temporary' | 'suspend_permanent' | 'delete' | 'escalate';
  performed_by_employee_id: string;
  reason: string | null;
  created_at: Date;
}

export interface ModerationAction {
  id: string;
  targetUserId: string;
  reviewCaseId: string | null;
  actionType: DbModerationActionRow['action_type'];
  performedByEmployeeId: string;
  reason: string | null;
  createdAt: string;
}

export function toModerationAction(row: DbModerationActionRow): ModerationAction {
  return {
    id: row.id,
    targetUserId: row.target_user_id,
    reviewCaseId: row.review_case_id,
    actionType: row.action_type,
    performedByEmployeeId: row.performed_by_employee_id,
    reason: row.reason,
    createdAt: row.created_at.toISOString(),
  };
}
