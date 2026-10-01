import { pool, withTransaction } from '../database/pool';
import { HttpError } from '../utils/httpError';
import { sosSensitiveRemoved } from '../models/SosEvent';
import {
  checkTransition,
  civilianStateOf,
  RESPONDER_STATES,
  TERMINAL_RESPONDER_STATES,
  type CivilianState,
  type ResponderState,
  type ResponderTransition,
} from './incidentStateMachine';

// Operations view of SOS events (the "incident queue") and the responder
// workflow. Responder actions go through the state machine in
// incidentStateMachine.ts, are appended to sos_incident_updates, and move
// sos_events.ops_status. The civilian's own status is never changed here,
// and a civilian marking themselves safe never removes an incident from
// the queue — only a responder closes it.

export type IncidentAction = ResponderTransition | 'note';
export type TimelineAction = IncidentAction | 'civilian_state';

export interface IncidentSummary {
  id: string;
  eventId: string;
  category: string;
  eventSource: string;
  opsStatus: ResponderState;
  civilianState: CivilianState;
  /** Raw sos_events.status, kept for API compatibility. */
  reporterStatus: string;
  originVerificationState: string;
  assignedEmployeeId: string | null;
  /** Approximate (≈1 km) for the queue; exact location is in the detail view. Null once removed under retention. */
  approximateLatitude: number | null;
  approximateLongitude: number | null;
  receivedAt: string;
  /** Message and location removed under the retention policy (or due for removal). */
  sensitiveRemoved: boolean;
}

export interface IncidentLifecycle {
  closedAt: string | null;
  /** When message, location, note text and delivery log were removed; null if not yet. */
  sensitiveRedactedAt: string | null;
  /** When the link to the reporter's account and device was removed. */
  deidentifiedAt: string | null;
  retentionHold: { since: string; reason: string; byEmployeeId: string } | null;
}

export interface IncidentDetail extends Omit<IncidentSummary, 'approximateLatitude' | 'approximateLongitude'> {
  /** The civilian's own SOS text; null when sensitive details are withheld. */
  message: string | null;
  /**
   * True when the exact location, the reporter's phone number, the SOS
   * message and responder note text are included (SOS_RESPOND). Otherwise
   * the location is approximate and those fields are null.
   */
  includesSensitiveDetails: boolean;
  lifecycle: IncidentLifecycle;
  latitude: number | null;
  longitude: number | null;
  locationAccuracyM: number | null;
  reporter: { displayName: string | null; phoneNumber: string | null } | null;
  timeline: Array<{
    action: TimelineAction;
    employeeId: string | null;
    actorRole: string | null;
    previousState: string | null;
    newState: string | null;
    assignedEmployeeId: string | null;
    note: string | null;
    /** A note exists but is withheld from this viewer. */
    noteHidden: boolean;
    /** The note text was removed under the retention policy. */
    noteRemoved: boolean;
    at: string;
  }>;
}

export type QueueScope = 'active' | 'closed' | 'all';
export const QUEUE_PAGE_DEFAULT = 100;
export const QUEUE_PAGE_MAX = 200;

interface DbIncidentRow {
  id: string;
  event_id: string;
  category: string;
  event_source: string;
  ops_status: ResponderState;
  status: string;
  origin_verification_state: string;
  assigned_employee_id: string | null;
  latitude: string | null;
  longitude: string | null;
  location_accuracy_m: string | null;
  message: string | null;
  server_received_at: Date;
  /** server_received_at in UTC at full (microsecond) precision, for cursors. */
  received_key: string;
  reporter_name: string | null;
  reporter_phone: string | null;
  user_id: string | null;
  ops_closed_at: Date | null;
  sensitive_redacted_at: Date | null;
  deidentified_at: Date | null;
  retention_hold_at: Date | null;
  retention_hold_reason: string | null;
  retention_hold_by_employee_id: string | null;
}

const num = (v: string | null) => (v === null ? null : Number(v));
/** Two decimals ≈ 1.1 km: enough to triage without exposing a precise location. */
const approx = (v: string | null) => (v === null ? null : Math.round(Number(v) * 100) / 100);

function summary(row: DbIncidentRow): IncidentSummary {
  const removed = sosSensitiveRemoved(row);
  return {
    id: row.id,
    eventId: row.event_id,
    category: row.category,
    eventSource: row.event_source,
    opsStatus: row.ops_status,
    civilianState: civilianStateOf(row.status),
    reporterStatus: row.status,
    originVerificationState: row.origin_verification_state,
    assignedEmployeeId: row.assigned_employee_id,
    approximateLatitude: removed ? null : approx(row.latitude),
    approximateLongitude: removed ? null : approx(row.longitude),
    receivedAt: row.server_received_at.toISOString(),
    sensitiveRemoved: removed,
  };
}

const SELECT = `
  SELECT e.id, e.event_id, e.category, e.event_source, e.ops_status, e.status, e.origin_verification_state,
         e.assigned_employee_id, e.latitude, e.longitude, e.location_accuracy_m, e.message, e.server_received_at,
         e.user_id, u.display_name AS reporter_name, u.phone_number AS reporter_phone,
         to_char(e.server_received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS received_key,
         e.ops_closed_at, e.sensitive_redacted_at, e.deidentified_at,
         e.retention_hold_at, e.retention_hold_reason, e.retention_hold_by_employee_id
  FROM sos_events e
  LEFT JOIN users u ON u.id = e.user_id`;

/**
 * Opaque cursor: the last row's (received time, id), newest first. The time
 * keeps PostgreSQL's microseconds — a millisecond JavaScript Date would
 * skip rows received within the same millisecond.
 */
export function encodeCursor(receivedAt: string, id: string): string {
  return Buffer.from(`${receivedAt}|${id}`, 'utf8').toString('base64url');
}

function decodeCursor(cursor: string): { receivedAt: string; id: string } {
  const [receivedAt, id] = Buffer.from(cursor, 'base64url').toString('utf8').split('|');
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const utcMicros = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
  if (!receivedAt || !id || !utcMicros.test(receivedAt) || !uuid.test(id)) {
    throw HttpError.badRequest('Invalid cursor');
  }
  return { receivedAt, id };
}

/**
 * The queue, newest first. 'active' = every incident a responder has not
 * closed (resolved / stood_down), whatever the civilian state — an
 * incident whose reporter is now safe or cancelled stays until a responder
 * closes it, with `civilianState` showing the change.
 */
export interface QueueFilters {
  opsStatus?: ResponderState;
  civilianState?: CivilianState;
  /** An employee id, or 'unassigned'. */
  assignee?: string;
}

const CIVILIAN_STATUSES: Record<CivilianState, string[]> = {
  active: ['open', 'acknowledged'],
  safe: ['resolved'],
  cancelled: ['false_alarm'],
};

export async function listIncidents(
  options: { scope?: QueueScope; limit?: number; cursor?: string } & QueueFilters = {},
): Promise<{ incidents: IncidentSummary[]; nextCursor: string | null }> {
  const scope = options.scope ?? 'active';
  const limit = Math.min(Math.max(options.limit ?? QUEUE_PAGE_DEFAULT, 1), QUEUE_PAGE_MAX);
  const where: string[] = [];
  const params: unknown[] = [];
  if (scope !== 'all') {
    params.push(TERMINAL_RESPONDER_STATES);
    where.push(`e.ops_status ${scope === 'active' ? '<> ALL' : '= ANY'}($${params.length}::varchar[])`);
  }
  if (options.opsStatus) {
    params.push(options.opsStatus);
    where.push(`e.ops_status = $${params.length}`);
  }
  if (options.civilianState) {
    params.push(CIVILIAN_STATUSES[options.civilianState]);
    where.push(`e.status = ANY($${params.length}::varchar[])`);
  }
  if (options.assignee === 'unassigned') {
    where.push('e.assigned_employee_id IS NULL');
  } else if (options.assignee) {
    params.push(options.assignee);
    where.push(`e.assigned_employee_id = $${params.length}::uuid`);
  }
  if (options.cursor) {
    const c = decodeCursor(options.cursor);
    params.push(c.receivedAt, c.id);
    where.push(`(e.server_received_at, e.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`);
  }
  params.push(limit + 1);
  const { rows } = await pool.query<DbIncidentRow>(
    `${SELECT} ${where.length ? `WHERE ${where.join(' AND ')}` : ''}
     ORDER BY e.server_received_at DESC, e.id DESC LIMIT $${params.length}`,
    params,
  );
  const pageRows = rows.slice(0, limit);
  const last = pageRows[pageRows.length - 1];
  return {
    incidents: pageRows.map(summary),
    nextCursor: rows.length > limit && last ? encodeCursor(last.received_key, last.id) : null,
  };
}

/**
 * Incident detail. Without `includeSensitive` the location stays
 * approximate, and the phone number, SOS message and note text are withheld.
 */
export async function getIncident(id: string, options: { includeSensitive: boolean }): Promise<IncidentDetail> {
  const { rows } = await pool.query<DbIncidentRow>(`${SELECT} WHERE e.id = $1`, [id]);
  const row = rows[0];
  if (!row) throw HttpError.notFound('Incident not found');
  const timeline = await pool.query<{
    action: TimelineAction;
    employee_id: string | null;
    actor_role: string | null;
    previous_state: string | null;
    new_state: string | null;
    assigned_employee_id: string | null;
    note: string | null;
    note_redacted_at: Date | null;
    created_at: Date;
  }>(
    `SELECT action, employee_id, actor_role, previous_state, new_state, assigned_employee_id, note, note_redacted_at, created_at
     FROM sos_incident_updates WHERE sos_event_id = $1 ORDER BY created_at, id`,
    [id],
  );
  const s = summary(row);
  // Past retention, nothing sensitive is served — to anyone — even if the
  // purge job has not run yet.
  const exact = options.includeSensitive && !s.sensitiveRemoved;
  return {
    id: s.id,
    eventId: s.eventId,
    category: s.category,
    eventSource: s.eventSource,
    opsStatus: s.opsStatus,
    civilianState: s.civilianState,
    reporterStatus: s.reporterStatus,
    originVerificationState: s.originVerificationState,
    assignedEmployeeId: s.assignedEmployeeId,
    receivedAt: s.receivedAt,
    message: exact ? row.message : null,
    includesSensitiveDetails: exact,
    sensitiveRemoved: s.sensitiveRemoved,
    lifecycle: {
      closedAt: row.ops_closed_at?.toISOString() ?? null,
      sensitiveRedactedAt: row.sensitive_redacted_at?.toISOString() ?? null,
      deidentifiedAt: row.deidentified_at?.toISOString() ?? null,
      retentionHold:
        row.retention_hold_at && row.retention_hold_reason && row.retention_hold_by_employee_id
          ? { since: row.retention_hold_at.toISOString(), reason: row.retention_hold_reason, byEmployeeId: row.retention_hold_by_employee_id }
          : null,
    },
    latitude: s.sensitiveRemoved ? null : exact ? num(row.latitude) : s.approximateLatitude,
    longitude: s.sensitiveRemoved ? null : exact ? num(row.longitude) : s.approximateLongitude,
    locationAccuracyM: exact ? num(row.location_accuracy_m) : null,
    // Unverified relayed events have no account behind them.
    reporter: row.user_id
      ? { displayName: row.reporter_name, phoneNumber: exact ? row.reporter_phone : null }
      : null,
    timeline: timeline.rows.map((t) => ({
      action: t.action,
      employeeId: t.employee_id,
      actorRole: t.actor_role,
      previousState: t.previous_state,
      newState: t.new_state,
      assignedEmployeeId: t.assigned_employee_id,
      note: exact ? t.note : null,
      noteHidden: !exact && t.note !== null && !s.sensitiveRemoved,
      noteRemoved: t.note_redacted_at !== null || (s.sensitiveRemoved && t.note !== null),
      at: t.created_at.toISOString(),
    })),
  };
}

export interface IncidentActor {
  id: string;
  role: string;
  /** Holds SOS_ASSIGN: may assign, stand down, and record progress for any assignee. */
  canAssign: boolean;
}

export interface IncidentUpdateResult {
  previousState: ResponderState;
  newState: ResponderState;
  civilianState: CivilianState;
}

function invalidTransition(message: string): HttpError {
  return new HttpError(409, 'INVALID_TRANSITION', message);
}

/**
 * Records a responder action through the state machine. Rules beyond the
 * transitions themselves:
 * - assigning and standing down need SOS_ASSIGN (checked by the caller as
 *   `canAssign`); a stand-down needs a reason;
 * - en_route / arrived / assisting / resolved are recorded by the assigned
 *   responder, or by someone with SOS_ASSIGN on their behalf;
 * - notes never change the state and are allowed in every state.
 */
export async function recordIncidentUpdate(
  actor: IncidentActor,
  id: string,
  input: { action: IncidentAction; note?: string; assignedEmployeeId?: string },
): Promise<IncidentUpdateResult> {
  return withTransaction(async (client) => {
    const { rows } = await client.query<{ ops_status: ResponderState; status: string; assigned_employee_id: string | null }>(
      'SELECT ops_status, status, assigned_employee_id FROM sos_events WHERE id = $1 FOR UPDATE',
      [id],
    );
    const current = rows[0];
    if (!current) throw HttpError.notFound('Incident not found');
    const from = current.ops_status;
    const civilianState = civilianStateOf(current.status);

    if (input.action === 'note') {
      if (!input.note) throw HttpError.badRequest('A note needs text');
      await client.query(
        `INSERT INTO sos_incident_updates (sos_event_id, employee_id, actor_role, action, previous_state, new_state, note)
         VALUES ($1, $2, $3, 'note', $4, $4, $5)`,
        [id, actor.id, actor.role, from, input.note],
      );
      return { previousState: from, newState: from, civilianState };
    }

    const to = input.action;
    if ((to === 'assigned' || to === 'stood_down') && !actor.canAssign) {
      throw HttpError.forbidden('Missing required permission: SOS_ASSIGN');
    }
    if (to === 'assigned' && !input.assignedEmployeeId) {
      throw HttpError.badRequest('assignedEmployeeId is required to assign');
    }
    if (to === 'stood_down' && !input.note) {
      throw HttpError.badRequest('Standing down needs a reason in `note`');
    }
    const check = checkTransition(from, to, {
      current: current.assigned_employee_id,
      next: input.assignedEmployeeId,
    });
    if (!check.ok) throw invalidTransition(check.message);

    const onScene = to === 'en_route' || to === 'arrived' || to === 'assisting' || to === 'resolved';
    if (onScene && current.assigned_employee_id !== actor.id && !actor.canAssign) {
      throw HttpError.forbidden('Only the assigned responder (or a dispatcher with SOS_ASSIGN) can record this');
    }
    if (to === 'assigned') {
      const assignee = await client.query("SELECT 1 FROM employees WHERE id = $1 AND status = 'active'", [
        input.assignedEmployeeId,
      ]);
      if (assignee.rowCount === 0) throw HttpError.badRequest('The assignee is not an active employee');
    }

    await client.query(
      `INSERT INTO sos_incident_updates
         (sos_event_id, employee_id, actor_role, action, previous_state, new_state, assigned_employee_id, note)
       VALUES ($1, $2, $3, $4, $5, $4, $6, $7)`,
      [id, actor.id, actor.role, to, from, to === 'assigned' ? input.assignedEmployeeId : null, input.note ?? null],
    );
    await client.query(
      `UPDATE sos_events SET ops_status = $2::varchar,
         assigned_employee_id = CASE WHEN $2::varchar = 'assigned' THEN $3::uuid ELSE assigned_employee_id END,
         -- Retention periods count from closure (migration 011).
         ops_closed_at = CASE WHEN $2::varchar IN ('resolved', 'stood_down') THEN now() ELSE ops_closed_at END
       WHERE id = $1`,
      [id, to, input.assignedEmployeeId ?? null],
    );
    return { previousState: from, newState: to, civilianState };
  });
}

export interface IncidentCounts {
  /** When the counts were computed (server time). */
  generatedAt: string;
  /** Records in the ResQNet operations system by responder state. */
  byResponderState: Record<ResponderState, number>;
  /** Not closed by a responder, but the reporter has marked themselves safe / cancelled. */
  openButCivilianSafe: number;
  openButCivilianCancelled: number;
  /** Received time of the oldest incident nobody has acknowledged yet. */
  oldestUnacknowledgedAt: string | null;
}

/** Counts for the operations dashboard, computed in the database. */
export async function getIncidentCounts(): Promise<IncidentCounts> {
  const { rows } = await pool.query<{ ops_status: ResponderState; n: number }>(
    'SELECT ops_status, count(*)::int AS n FROM sos_events GROUP BY ops_status',
  );
  const extra = await pool.query<{ safe: number; cancelled: number; oldest: Date | null; now: Date }>(
    `SELECT
       count(*) FILTER (WHERE ops_status <> ALL($1::varchar[]) AND status = 'resolved')::int AS safe,
       count(*) FILTER (WHERE ops_status <> ALL($1::varchar[]) AND status = 'false_alarm')::int AS cancelled,
       min(server_received_at) FILTER (WHERE ops_status = 'reported') AS oldest,
       now() AS now
     FROM sos_events`,
    [TERMINAL_RESPONDER_STATES],
  );
  const byResponderState = Object.fromEntries(RESPONDER_STATES.map((s) => [s, 0])) as Record<ResponderState, number>;
  for (const r of rows) byResponderState[r.ops_status] = r.n;
  const e = extra.rows[0]!;
  return {
    generatedAt: e.now.toISOString(),
    byResponderState,
    openButCivilianSafe: e.safe,
    openButCivilianCancelled: e.cancelled,
    oldestUnacknowledgedAt: e.oldest?.toISOString() ?? null,
  };
}

export interface EligibleResponder {
  id: string;
  displayName: string;
  role: string;
  /** Incidents currently assigned to them and not yet closed. */
  openAssignments: number;
}

/**
 * Active employees who can respond (SOS_RESPOND, or super_admin). Only the
 * name and role are returned — this list is for choosing an assignee, not
 * for employee administration.
 */
export async function listEligibleResponders(): Promise<EligibleResponder[]> {
  const { rows } = await pool.query<{ id: string; display_name: string; role: string; open_assignments: number }>(
    `SELECT e.id, e.display_name, e.role,
            (SELECT count(*)::int FROM sos_events s
             WHERE s.assigned_employee_id = e.id AND s.ops_status <> ALL($1::varchar[])) AS open_assignments
     FROM employees e
     WHERE e.status = 'active'
       AND (e.role = 'super_admin'
            OR EXISTS (SELECT 1 FROM employee_permissions p WHERE p.employee_id = e.id AND p.permission = 'SOS_RESPOND'))
     ORDER BY e.display_name
     LIMIT 500`,
    [TERMINAL_RESPONDER_STATES],
  );
  return rows.map((r) => ({ id: r.id, displayName: r.display_name, role: r.role, openAssignments: r.open_assignments }));
}

/**
 * Places or lifts a retention hold on one incident. A hold pauses
 * redaction and de-identification by the retention job; it is an
 * operational flag, not a legal determination. Not possible once the
 * incident has been de-identified (there is nothing left to preserve).
 */
export async function setRetentionHold(
  employeeId: string,
  id: string,
  input: { hold: true; reason: string } | { hold: false },
): Promise<{ held: boolean; sensitiveAlreadyRedacted: boolean }> {
  const { rows } = await pool.query<{ deidentified_at: Date | null; sensitive_redacted_at: Date | null }>(
    input.hold
      ? `UPDATE sos_events SET retention_hold_at = now(), retention_hold_reason = $2, retention_hold_by_employee_id = $3
         WHERE id = $1 AND deidentified_at IS NULL
         RETURNING deidentified_at, sensitive_redacted_at`
      : `UPDATE sos_events SET retention_hold_at = NULL, retention_hold_reason = NULL, retention_hold_by_employee_id = NULL
         WHERE id = $1
         RETURNING deidentified_at, sensitive_redacted_at`,
    input.hold ? [id, input.reason, employeeId] : [id],
  );
  const row = rows[0];
  if (!row) {
    const exists = await pool.query('SELECT 1 FROM sos_events WHERE id = $1', [id]);
    if (exists.rowCount === 0) throw HttpError.notFound('Incident not found');
    throw HttpError.conflict('This incident has already been de-identified; there is nothing left to hold');
  }
  return { held: input.hold, sensitiveAlreadyRedacted: row.sensitive_redacted_at !== null };
}
