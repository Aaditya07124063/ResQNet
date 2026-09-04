import { pool } from '../database/pool';
import { logger } from '../utils/logger';

interface AuditEvent {
  actorUserId?: string | null;
  actorEmployeeId?: string | null;
  action: string;
  resourceType: string;
  resourceId?: string | null;
  outcome: 'success' | 'denied' | 'error';
  metadata?: Record<string, unknown> | null;
  ipAddress?: string | null;
}

// Fire-and-forget audit logging: a failure to write an audit row must never
// break the request it's describing, so errors are logged and swallowed
// rather than propagated. Never pass secrets/tokens/OTPs/message content in
// `metadata` — this is a durable, queryable table, not a scratch log.
export async function recordAuditEvent(event: AuditEvent): Promise<void> {
  try {
    await pool.query(
      `INSERT INTO audit_logs (actor_user_id, actor_employee_id, action, resource_type, resource_id, outcome, metadata, ip_address)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        event.actorUserId ?? null,
        event.actorEmployeeId ?? null,
        event.action,
        event.resourceType,
        event.resourceId ?? null,
        event.outcome,
        event.metadata ? JSON.stringify(event.metadata) : null,
        event.ipAddress ?? null,
      ],
    );
  } catch (err) {
    logger.error({ err, action: event.action }, 'Failed to write audit log entry');
  }
}
