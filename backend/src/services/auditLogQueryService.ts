import { pool } from '../database/pool';
import { redactAuditMetadata } from '../utils/auditRedaction';

// Read side of audit_logs for the operations portal (AUDIT_LOG_VIEW).
// Writers never store secrets (see auditLogService.ts); as defence in depth
// the reader still drops any metadata key that looks like one. IP
// addresses are not returned.

export { redactAuditMetadata };

export interface AuditLogEntry {
  id: string;
  at: string;
  actor:
    | { kind: 'employee'; id: string | null; displayName: string | null; role: string | null }
    | { kind: 'user'; id: string | null }
    | { kind: 'system' };
  action: string;
  resourceType: string;
  resourceId: string | null;
  outcome: 'success' | 'denied' | 'error';
  metadata: unknown;
}

export interface AuditLogQuery {
  resourceType?: string;
  resourceId?: string;
  /** Matches actions starting with this prefix, e.g. 'incident.'. */
  actionPrefix?: string;
  outcome?: 'success' | 'denied' | 'error';
  actorEmployeeId?: string;
  limit?: number;
  /** The id of the last entry of the previous page (entries are newest first). */
  before?: string;
}

export const AUDIT_PAGE_MAX = 200;

export async function listAuditLogs(query: AuditLogQuery): Promise<{ entries: AuditLogEntry[]; nextBefore: string | null }> {
  const limit = Math.min(Math.max(query.limit ?? 50, 1), AUDIT_PAGE_MAX);
  const where: string[] = [];
  const params: unknown[] = [];
  const add = (sql: (n: number) => string, value: unknown) => {
    params.push(value);
    where.push(sql(params.length));
  };
  if (query.resourceType) add((n) => `a.resource_type = $${n}`, query.resourceType);
  if (query.resourceId) add((n) => `a.resource_id = $${n}`, query.resourceId);
  if (query.actionPrefix) add((n) => `a.action LIKE $${n}`, `${query.actionPrefix.replace(/[\\%_]/g, '\\$&')}%`);
  if (query.outcome) add((n) => `a.outcome = $${n}`, query.outcome);
  if (query.actorEmployeeId) add((n) => `a.actor_employee_id = $${n}::uuid`, query.actorEmployeeId);
  if (query.before) add((n) => `a.id < $${n}::bigint`, query.before);
  params.push(limit + 1);
  const { rows } = await pool.query<{
    id: string;
    created_at: Date;
    actor_user_id: string | null;
    actor_employee_id: string | null;
    employee_name: string | null;
    employee_role: string | null;
    action: string;
    resource_type: string;
    resource_id: string | null;
    outcome: AuditLogEntry['outcome'];
    metadata: unknown;
  }>(
    `SELECT a.id::text AS id, a.created_at, a.actor_user_id, a.actor_employee_id,
            e.display_name AS employee_name, e.role AS employee_role,
            a.action, a.resource_type, a.resource_id, a.outcome, a.metadata
     FROM audit_logs a
     LEFT JOIN employees e ON e.id = a.actor_employee_id
     ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY a.id DESC
     LIMIT $${params.length}`,
    params,
  );
  const page = rows.slice(0, limit);
  return {
    entries: page.map((r) => ({
      id: r.id,
      at: r.created_at.toISOString(),
      actor: r.actor_employee_id
        ? { kind: 'employee', id: r.actor_employee_id, displayName: r.employee_name, role: r.employee_role }
        : r.actor_user_id
          ? { kind: 'user', id: r.actor_user_id }
          : { kind: 'system' },
      action: r.action,
      resourceType: r.resource_type,
      resourceId: r.resource_id,
      outcome: r.outcome,
      metadata: redactAuditMetadata(r.metadata),
    })),
    nextBefore: rows.length > limit ? page[page.length - 1]!.id : null,
  };
}
