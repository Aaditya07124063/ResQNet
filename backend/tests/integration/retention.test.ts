// Real-PostgreSQL tests for the data-lifecycle system: retention job,
// read-time masking, retention hold and account deletion. Opt-in like
// database.test.ts (RESQNET_INTEGRATION_DB=1, throwaway database only —
// every table is truncated).
import { createHash, randomUUID } from 'crypto';
import { pool } from '../../src/database/pool';
import { createSosEvent, listSosEvents, updateSosEventStatus } from '../../src/services/sosService';
import { getIncident, listIncidents, recordIncidentUpdate, setRetentionHold, type IncidentActor } from '../../src/services/incidentService';
import { runRetention, RETENTION_CATEGORIES, type RetentionCategory } from '../../src/services/retention/retentionJob';
import { retentionPolicyFromEnv, type RetentionPolicy } from '../../src/services/retention/retentionPolicy';
import { recordAuditEvent } from '../../src/services/auditLogService';
import { deleteAccount } from '../../src/services/accountDeletionService';
import { findNearbyEligibleUsers } from '../../src/services/nearbyAlertService';

const enabled = process.env.RESQNET_INTEGRATION_DB === '1';
const describeDb = enabled ? describe : describe.skip;

const DAY = 86_400_000;
const daysAgo = (now: Date, days: number, extraMs = 0) => new Date(now.getTime() - days * DAY + extraMs);
const policy = (overrides: Partial<RetentionPolicy> = {}): RetentionPolicy => ({ ...retentionPolicyFromEnv(), ...overrides });
const only = (...names: string[]): RetentionCategory[] => RETENTION_CATEGORIES.filter((c) => names.includes(c.name));
const hash = () => createHash('sha256').update(randomUUID()).digest('hex');

async function user(name = 'Person'): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    'INSERT INTO users (google_subject, display_name) VALUES ($1, $2) RETURNING id',
    [`g-${randomUUID()}`, name],
  );
  return rows[0]!.id;
}

async function employee(name: string, status: 'active' | 'disabled' = 'active'): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    "INSERT INTO employees (email, display_name, password_hash, role, status) VALUES ($1, $2, 'x', 'employee', $3) RETURNING id",
    [`${name}-${randomUUID()}@example.com`, name, status],
  );
  return rows[0]!.id;
}

async function sos(reporter: string): Promise<string> {
  const e = await createSosEvent(reporter, {
    eventId: randomUUID(),
    eventSource: 'manual',
    category: 'medical',
    message: 'Leg injury, allergic to penicillin',
    latitude: 27.717245,
    longitude: 85.323961,
    clientCreatedAt: new Date(),
  } as never);
  return e.id;
}

/** A responder-closed incident, closed at [closedAt], with a note and a delivery-log row. */
async function closedSos(reporter: string, responder: string, closedAt: Date): Promise<string> {
  const id = await sos(reporter);
  const actor: IncidentActor = { id: responder, role: 'employee', canAssign: true };
  await recordIncidentUpdate(actor, id, { action: 'note', note: 'Bleeding controlled' });
  await recordIncidentUpdate(actor, id, { action: 'stood_down', note: 'Handled by family' });
  await pool.query('UPDATE sos_events SET ops_closed_at = $2 WHERE id = $1', [id, closedAt]);
  await pool.query(
    `INSERT INTO sos_recipients (sos_event_id, recipient_phone_number, channel, status, recipient_category)
     VALUES ($1, '+9779800000001', 'sms', 'sent', 'trusted_contact')`,
    [id],
  );
  return id;
}

const row = async (id: string) =>
  (await pool.query('SELECT * FROM sos_events WHERE id = $1', [id])).rows[0] as Record<string, unknown> | undefined;

describeDb('data lifecycle (real PostgreSQL)', () => {
  let responder: string;

  beforeAll(async () => {
    const { rows } = await pool.query<{ tablename: string }>(
      "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'",
    );
    await pool.query(`TRUNCATE ${rows.map((r) => `"${r.tablename}"`).join(', ')} RESTART IDENTITY CASCADE`);
    responder = await employee('responder');
  });

  afterAll(async () => {
    await pool.end();
  });

  it('redacts a closed incident exactly at the boundary, keeps the operational record, and protects open/held incidents', async () => {
    const now = new Date();
    const p = policy();
    const reporter = await user('Reporter');
    const atCutoff = await closedSos(reporter, responder, daysAgo(now, p.sosSensitiveDays));
    const justInside = await closedSos(reporter, responder, daysAgo(now, p.sosSensitiveDays, 1000));
    const held = await closedSos(reporter, responder, daysAgo(now, 400));
    await setRetentionHold(responder, held, { hold: true, reason: 'Open investigation' });

    // Old but still open: assigned, and "reporter safe" while responders are working.
    const openAssigned = await sos(reporter);
    await recordIncidentUpdate({ id: responder, role: 'employee', canAssign: true }, openAssigned, { action: 'assigned', assignedEmployeeId: responder });
    const openSafe = await sos(reporter);
    await updateSosEventStatus(reporter, openSafe, { status: 'resolved' });
    await pool.query("UPDATE sos_events SET server_received_at = $2 WHERE id = ANY($1)", [[openAssigned, openSafe], daysAgo(now, 900)]);

    const report = await runRetention({ now, policy: p, categories: only('sos_sensitive_redaction'), audit: false });
    expect(report.ok).toBe(true);

    const redacted = (await row(atCutoff))!;
    expect(redacted).toMatchObject({
      message: null,
      latitude: null,
      longitude: null,
      location_accuracy_m: null,
      origin_envelope_raw: null,
      origin_signature: null,
      category: 'medical',
      ops_status: 'stood_down',
    });
    expect(redacted.sensitive_redacted_at).not.toBeNull();
    expect(redacted.user_id).toBe(reporter); // not de-identified yet
    const timeline = await pool.query('SELECT action, note, note_redacted_at FROM sos_incident_updates WHERE sos_event_id = $1 ORDER BY id', [atCutoff]);
    expect(timeline.rows.map((t) => t.action)).toEqual(['note', 'stood_down']);
    expect(timeline.rows.every((t) => t.note === null && t.note_redacted_at !== null)).toBe(true);
    expect((await pool.query('SELECT 1 FROM sos_recipients WHERE sos_event_id = $1', [atCutoff])).rowCount).toBe(0);

    for (const untouched of [justInside, held, openAssigned, openSafe]) {
      const r = (await row(untouched))!;
      expect(r.sensitive_redacted_at).toBeNull();
      expect(r.message).not.toBeNull();
      expect(r.latitude).not.toBeNull();
    }
    expect((await pool.query('SELECT 1 FROM sos_recipients WHERE sos_event_id = $1', [held])).rowCount).toBe(1);
  });

  it('de-identifies only after redaction and the longer period; record deletion is off unless configured', async () => {
    const now = new Date();
    const p = policy({ sosSensitiveDays: 90, sosDeidentifyDays: 730 });
    const reporter = await user('Reporter');
    const old = await closedSos(reporter, responder, daysAgo(now, 731));
    const middle = await closedSos(reporter, responder, daysAgo(now, 200));

    const first = await runRetention({ now, policy: p, categories: only('sos_sensitive_redaction', 'sos_deidentify', 'sos_record_delete'), audit: false });
    expect(first.categories.find((c) => c.category === 'sos_record_delete')).toMatchObject({ skipped: 'disabled', affected: 0 });
    expect(await row(old)).toMatchObject({ user_id: null, origin_claimed_user_id: null });
    expect((await row(old))!.deidentified_at).not.toBeNull();
    expect((await row(middle))!.user_id).toBe(reporter);
    expect((await row(middle))!.sensitive_redacted_at).not.toBeNull();

    // With deletion configured: the row and its timeline go; employees are untouched.
    await runRetention({ now, policy: { ...p, sosRecordDeleteDays: 730 }, categories: only('sos_record_delete'), audit: false });
    expect(await row(old)).toBeUndefined();
    expect((await pool.query('SELECT 1 FROM sos_incident_updates WHERE sos_event_id = $1', [old])).rowCount).toBe(0);
    expect((await pool.query('SELECT 1 FROM employees WHERE id = $1', [responder])).rowCount).toBe(1);
    expect(await row(middle)).toBeDefined();
  });

  it('never serves expired sensitive fields, even before the purge job has run', async () => {
    const now = new Date();
    const reporter = await user('Reporter');
    const expired = await closedSos(reporter, responder, daysAgo(now, retentionPolicyFromEnv().sosSensitiveDays + 1));
    const fresh = await sos(reporter);

    const detail = await getIncident(expired, { includeSensitive: true });
    expect(detail).toMatchObject({ sensitiveRemoved: true, includesSensitiveDetails: false, message: null, latitude: null, longitude: null });
    expect(detail.reporter?.phoneNumber ?? null).toBeNull();
    expect(detail.timeline.find((t) => t.action === 'note')).toMatchObject({ note: null, noteRemoved: true, noteHidden: false });
    expect(JSON.stringify(detail)).not.toMatch(/penicillin|Bleeding|27\.71/);
    const queued = (await listIncidents({ scope: 'closed', limit: 200 })).incidents.find((i) => i.id === expired)!;
    expect(queued).toMatchObject({ sensitiveRemoved: true, approximateLatitude: null });

    const own = await listSosEvents(reporter);
    expect(own.find((e) => e.id === expired)).toMatchObject({ sensitiveRemoved: true, message: null, latitude: null });
    expect(own.find((e) => e.id === fresh)).toMatchObject({ sensitiveRemoved: false, message: 'Leg injury, allergic to penicillin' });

    // Unauthorized (no SOS_RESPOND) on a fresh incident: approximate only, no message, no phone.
    const limited = await getIncident(fresh, { includeSensitive: false });
    expect(limited).toMatchObject({ message: null, latitude: 27.72, includesSensitiveDetails: false });
    expect(JSON.stringify(limited)).not.toMatch(/penicillin|27\.717245/);
  });

  it('sessions: ended long enough ago are deleted, valid ones never; disabled employees lose their sessions', async () => {
    const now = new Date();
    const u = await user();
    const insertSession = async (expires: Date, revoked: Date | null) =>
      (await pool.query<{ id: string }>(
        'INSERT INTO sessions (user_id, refresh_token_hash, expires_at, revoked_at) VALUES ($1, $2, $3, $4) RETURNING id',
        [u, hash(), expires, revoked],
      )).rows[0]!.id;
    const valid = await insertSession(new Date(now.getTime() + DAY), null);
    const expiredOld = await insertSession(daysAgo(now, 31), null);
    const expiredRecent = await insertSession(daysAgo(now, 29), null);
    const revokedOld = await insertSession(new Date(now.getTime() + DAY), daysAgo(now, 31));

    const active = await employee('active');
    const disabled = await employee('gone', 'disabled');
    const empSession = async (emp: string) =>
      (await pool.query<{ id: string }>(
        'INSERT INTO employee_sessions (employee_id, refresh_token_hash, expires_at) VALUES ($1, $2, $3) RETURNING id',
        [emp, hash(), new Date(now.getTime() + DAY)],
      )).rows[0]!.id;
    const activeSession = await empSession(active);
    const disabledSession = await empSession(disabled);

    await runRetention({ now, categories: only('user_sessions', 'employee_sessions', 'disabled_employee_sessions'), audit: false });
    const left = (await pool.query<{ id: string }>('SELECT id FROM sessions WHERE user_id = $1', [u])).rows.map((r) => r.id);
    expect(left.sort()).toEqual([valid, expiredRecent].sort());
    expect(left).not.toContain(expiredOld);
    expect(left).not.toContain(revokedOld);
    const emp = await pool.query<{ id: string; revoked_at: Date | null }>('SELECT id, revoked_at FROM employee_sessions WHERE id = ANY($1)', [[activeSession, disabledSession]]);
    expect(emp.rows.find((r) => r.id === activeSession)!.revoked_at).toBeNull();
    expect(emp.rows.find((r) => r.id === disabledSession)!.revoked_at).not.toBeNull();
    // The disabled employee's account and audit trail remain.
    expect((await pool.query('SELECT 1 FROM employees WHERE id = $1', [disabled])).rowCount).toBe(1);
  });

  it('bounded batches: a small batch leaves the rest for the next run; repeated runs are idempotent', async () => {
    const now = new Date();
    for (let i = 0; i < 5; i++) {
      await pool.query(
        `INSERT INTO verification_attempts (channel, target, purpose, code_hash, max_attempts, expires_at, created_at)
         VALUES ('sms', '+9779800000002', 'login', $1, 5, $2, $2)`,
        [hash(), daysAgo(now, 40)],
      );
    }
    await pool.query(
      `INSERT INTO verification_attempts (channel, target, purpose, code_hash, max_attempts, expires_at, created_at)
       VALUES ('sms', '+9779800000002', 'login', $1, 5, $2, $3)`,
      [hash(), new Date(now.getTime() + 600_000), now],
    );
    const small = policy({ batchSize: 2, maxBatchesPerCategory: 1 });
    const runs = [];
    for (let i = 0; i < 4; i++) runs.push((await runRetention({ now, policy: small, categories: only('otp_attempts'), audit: false })).categories[0]!);
    expect(runs.map((r) => [r.affected, r.more])).toEqual([[2, true], [2, true], [1, false], [0, false]]);
    expect((await pool.query('SELECT count(*)::int AS n FROM verification_attempts')).rows[0].n).toBe(1); // the live code stays

    const again = await runRetention({ now, audit: false });
    const twice = await runRetention({ now, audit: false });
    expect(again.ok && twice.ok).toBe(true);
    expect(twice.categories.every((c) => c.affected === 0)).toBe(true);
  });

  it('dry run counts eligible rows and changes nothing', async () => {
    const now = new Date();
    const u = await user();
    await pool.query(
      'INSERT INTO seismic_reports (user_id, latitude, longitude, detector_score, reported_at) VALUES ($1, 27.7, 85.3, 0.9, $2)',
      [u, daysAgo(now, 45)],
    );
    const dry = await runRetention({ now, dryRun: true, categories: only('seismic_reports'), audit: false });
    expect(dry.categories[0]).toMatchObject({ examined: 1, affected: 0 });
    expect((await pool.query('SELECT 1 FROM seismic_reports WHERE user_id = $1', [u])).rowCount).toBe(1);
    await runRetention({ now, categories: only('seismic_reports'), audit: false });
    expect((await pool.query('SELECT 1 FROM seismic_reports WHERE user_id = $1', [u])).rowCount).toBe(0);
  });

  it('nearby locations: stale ones are ignored before the purge and deleted by it', async () => {
    const now = new Date();
    const reporter = await user('Reporter');
    const [fresh, stale] = [await user('Fresh'), await user('Stale')];
    for (const [u, at] of [[fresh, now], [stale, daysAgo(now, 45)]] as const) {
      await pool.query('INSERT INTO nearby_emergency_preferences (user_id, enabled) VALUES ($1, TRUE)', [u]);
      await pool.query('INSERT INTO nearby_alert_locations (user_id, latitude, longitude, updated_at) VALUES ($1, 27.7172, 85.3240, $2)', [u, at]);
    }
    const found = (await findNearbyEligibleUsers(reporter, 27.7172, 85.324)).map((n) => (n as { userId: string }).userId);
    expect(found).toContain(fresh);
    expect(found).not.toContain(stale);
    await runRetention({ now, categories: only('stale_nearby_locations'), audit: false });
    const left = (await pool.query<{ user_id: string }>('SELECT user_id FROM nearby_alert_locations')).rows.map((r) => r.user_id);
    expect(left).toContain(fresh);
    expect(left).not.toContain(stale);
  });

  it('audit log: IPs are dropped after their window, entries after theirs; metadata is redacted when written', async () => {
    const now = new Date();
    const insert = async (at: Date) =>
      (await pool.query<{ id: string }>(
        "INSERT INTO audit_logs (action, resource_type, outcome, ip_address, created_at) VALUES ('test.entry', 'system', 'success', '203.0.113.9', $1) RETURNING id::text AS id",
        [at],
      )).rows[0]!.id;
    const recent = await insert(daysAgo(now, 10));
    const ipOld = await insert(daysAgo(now, 100));
    const veryOld = await insert(daysAgo(now, 800));
    await runRetention({ now, categories: only('audit_ip_addresses', 'audit_logs'), audit: false });
    const rows = await pool.query<{ id: string; ip: string | null }>(
      'SELECT id::text AS id, host(ip_address) AS ip FROM audit_logs WHERE id = ANY($1::bigint[])',
      [[recent, ipOld, veryOld]],
    );
    expect(rows.rows.find((r) => r.id === recent)!.ip).toBe('203.0.113.9');
    expect(rows.rows.find((r) => r.id === ipOld)!.ip).toBeNull();
    expect(rows.rows.some((r) => r.id === veryOld)).toBe(false);

    await recordAuditEvent({
      action: 'test.redaction',
      resourceType: 'system',
      outcome: 'success',
      metadata: { latitude: 27.7, message: 'I am hurt', phoneNumber: '+9779800000003', medications: 'x', refreshToken: 't', hasNote: true, newState: 'en_route' },
    });
    const stored = await pool.query("SELECT metadata FROM audit_logs WHERE action = 'test.redaction'");
    expect(stored.rows[0].metadata).toEqual({
      latitude: '[redacted]',
      message: '[redacted]',
      phoneNumber: '[redacted]',
      medications: '[redacted]',
      refreshToken: '[redacted]',
      hasNote: true,
      newState: 'en_route',
    });
  });

  it('alerts, devices, device keys and chat location messages follow their own periods; current ones stay', async () => {
    const now = new Date();
    const alert = async (status: string, updatedAt: Date, expiresAt: Date | null) =>
      (await pool.query<{ id: string }>(
        `INSERT INTO emergency_alerts (source_type, source_name, category, severity, status, title, body, district, expires_at, updated_at)
         VALUES ('resqnet_system', 'Ops', 'flood', 'watch', $1, 'Flood watch', 'b', 'Kaski', $3, $2) RETURNING id`,
        [status, updatedAt, expiresAt],
      )).rows[0]!.id;
    const current = await alert('active', daysAgo(now, 500), new Date(now.getTime() + DAY));
    const resolvedOld = await alert('resolved', daysAgo(now, 400), null);
    const expiredLongAgo = await alert('active', daysAgo(now, 400), daysAgo(now, 400));
    // updated_at is maintained by a trigger; backdate it with the trigger off.
    await pool.query('ALTER TABLE emergency_alerts DISABLE TRIGGER trg_emergency_alerts_updated_at');
    try {
      await pool.query('UPDATE emergency_alerts SET updated_at = $2 WHERE id = ANY($1)', [[current, resolvedOld, expiredLongAgo], daysAgo(now, 400)]);
    } finally {
      await pool.query('ALTER TABLE emergency_alerts ENABLE TRIGGER trg_emergency_alerts_updated_at');
    }

    const u = await user();
    const other = await user();
    const [a, b] = u < other ? [u, other] : [other, u];
    const conv = (await pool.query<{ id: string }>("INSERT INTO conversations (type, direct_user_a_id, direct_user_b_id) VALUES ('direct', $1, $2) RETURNING id", [a, b])).rows[0]!.id;
    const msg = async (type: 'text' | 'location', at: Date) =>
      (await pool.query<{ id: string }>(
        `INSERT INTO messages (conversation_id, sender_user_id, client_message_id, message_type, body, latitude, longitude, client_created_at, server_received_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8) RETURNING id`,
        [conv, u, randomUUID(), type, type === 'text' ? 'hello' : null, type === 'location' ? 27.7 : null, type === 'location' ? 85.3 : null, at],
      )).rows[0]!.id;
    const oldLocation = await msg('location', daysAgo(now, 40));
    const newLocation = await msg('location', daysAgo(now, 5));
    const oldText = await msg('text', daysAgo(now, 400));

    const device = async (lastSeen: Date) =>
      (await pool.query<{ id: string }>("INSERT INTO devices (user_id, platform, push_provider, push_token, last_seen_at) VALUES ($1, 'android', 'fcm', $2, $3) RETURNING id", [u, randomUUID(), lastSeen])).rows[0]!.id;
    const staleDevice = await device(daysAgo(now, 200));
    const liveDevice = await device(now);
    const key = async (revoked: Date | null) =>
      (await pool.query<{ id: string }>(
        "INSERT INTO device_keys (user_id, device_id, key_id, public_key, algorithm, revoked_at) VALUES ($1, $2, $3, 'pem', 'ecdsa-p256', $4) RETURNING id",
        [u, randomUUID(), randomUUID().slice(0, 16), revoked],
      )).rows[0]!.id;
    const oldRevokedKey = await key(daysAgo(now, 400));
    const activeKey = await key(null);

    const report = await runRetention({ now, categories: only('closed_alerts', 'chat_location_messages', 'stale_devices', 'revoked_device_keys'), audit: false });
    expect(report.ok).toBe(true);
    const exists = async (table: string, id: string) => ((await pool.query(`SELECT 1 FROM ${table} WHERE id = $1`, [id])).rowCount ?? 0) > 0;
    expect(await exists('emergency_alerts', current)).toBe(true);
    expect(await exists('emergency_alerts', resolvedOld)).toBe(false);
    expect(await exists('emergency_alerts', expiredLongAgo)).toBe(false);
    expect(await exists('messages', oldLocation)).toBe(false);
    expect(await exists('messages', newLocation)).toBe(true);
    expect(await exists('messages', oldText)).toBe(true); // ordinary messages have no automatic period
    expect(await exists('devices', staleDevice)).toBe(false);
    expect(await exists('devices', liveDevice)).toBe(true);
    expect(await exists('device_keys', oldRevokedKey)).toBe(false);
    expect(await exists('device_keys', activeKey)).toBe(true);
  });

  it('a failing category rolls back completely and does not stop the others; the run is reported as failed', async () => {
    const now = new Date();
    const reporter = await user();
    const target = await closedSos(reporter, responder, daysAgo(now, 200));
    const broken: RetentionCategory = {
      ...RETENTION_CATEGORIES.find((c) => c.name === 'sos_sensitive_redaction')!,
      name: 'broken_category',
      // The action succeeds, then a follow-up fails: nothing may remain changed.
      followUps: ['UPDATE sos_events SET no_such_column = 1 WHERE id = ANY(:keys)'],
    };
    const u = await user();
    await pool.query(
      'INSERT INTO seismic_reports (user_id, latitude, longitude, detector_score, reported_at) VALUES ($1, 27.7, 85.3, 0.9, $2)',
      [u, daysAgo(now, 45)],
    );
    const report = await runRetention({ now, categories: [broken, ...only('seismic_reports')], audit: false });
    expect(report.ok).toBe(false);
    expect(report.categories[0]).toMatchObject({ category: 'broken_category', ok: false, errorCode: '42703', affected: 0 });
    expect(report.categories[1]).toMatchObject({ category: 'seismic_reports', ok: true, affected: 1 });
    const r = (await row(target))!;
    expect(r.sensitive_redacted_at).toBeNull();
    expect(r.message).not.toBeNull();
    // The next (correct) run completes the work.
    await runRetention({ now, categories: only('sos_sensitive_redaction'), audit: false });
    expect((await row(target))!.message).toBeNull();
  });

  it('only one run at a time (advisory lock); a run is recorded in the audit log with counts only', async () => {
    const holder = await pool.connect();
    try {
      await holder.query("SELECT pg_advisory_lock(hashtext('resqnet.retention'))");
      const skipped = await runRetention({ audit: false });
      expect(skipped).toMatchObject({ skippedLocked: true, categories: [] });
    } finally {
      await holder.query("SELECT pg_advisory_unlock(hashtext('resqnet.retention'))");
      holder.release();
    }
    await runRetention({ categories: only('seismic_reports') });
    const entry = await pool.query("SELECT metadata, outcome FROM audit_logs WHERE action = 'retention.run' ORDER BY id DESC LIMIT 1");
    expect(entry.rows[0].outcome).toBe('success');
    expect(Object.keys(entry.rows[0].metadata.categories)).toEqual(['seismic_reports']);
  });

  it('account deletion: refused with an open or held incident; otherwise keeps a de-identified incident record', async () => {
    const now = new Date();
    const person = await user('Person');
    const open = await sos(person);
    await expect(deleteAccount(person)).rejects.toMatchObject({ status: 409, code: 'ACTIVE_INCIDENT' });
    expect((await pool.query('SELECT 1 FROM users WHERE id = $1', [person])).rowCount).toBe(1);

    await recordIncidentUpdate({ id: responder, role: 'employee', canAssign: true }, open, { action: 'stood_down', note: 'Checked, fine' });
    await setRetentionHold(responder, open, { hold: true, reason: 'Complaint under review' });
    await expect(deleteAccount(person)).rejects.toMatchObject({ status: 409, code: 'RETENTION_HOLD' });
    await setRetentionHold(responder, open, { hold: false });

    // Profile with medical details, a session, and two groups (one shared, one alone).
    await pool.query("INSERT INTO user_profiles (user_id, blood_group, allergies) VALUES ($1, 'O+', 'penicillin')", [person]);
    await pool.query("INSERT INTO sessions (user_id, refresh_token_hash, expires_at) VALUES ($1, $2, $3)", [person, hash(), new Date(now.getTime() + DAY)]);
    const friend = await user('Friend');
    const shared = (await pool.query<{ id: string }>("INSERT INTO groups (name, owner_user_id) VALUES ('Trek', $1) RETURNING id", [person])).rows[0]!.id;
    await pool.query("INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'owner'), ($1, $3, 'member')", [shared, person, friend]);
    const alone = (await pool.query<{ id: string }>("INSERT INTO groups (name, owner_user_id) VALUES ('Solo', $1) RETURNING id", [person])).rows[0]!.id;
    await pool.query("INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'owner')", [alone, person]);
    await recordAuditEvent({ actorUserId: person, action: 'test.by_person', resourceType: 'system', outcome: 'success' });

    const result = await deleteAccount(person);
    expect(result).toEqual({ incidentsDeidentified: 1, groupsTransferred: 1, groupsDeleted: 1 });

    expect((await pool.query('SELECT 1 FROM users WHERE id = $1', [person])).rowCount).toBe(0);
    expect((await pool.query('SELECT 1 FROM user_profiles WHERE user_id = $1', [person])).rowCount).toBe(0);
    expect((await pool.query('SELECT 1 FROM sessions WHERE user_id = $1', [person])).rowCount).toBe(0);
    const incident = (await row(open))!;
    expect(incident).toMatchObject({ user_id: null, message: null, latitude: null, category: 'medical', ops_status: 'stood_down' });
    expect(incident.deidentified_at).not.toBeNull();
    expect((await pool.query('SELECT count(*)::int AS n FROM sos_incident_updates WHERE sos_event_id = $1', [open])).rows[0].n).toBe(1);
    expect((await pool.query<{ owner_user_id: string }>('SELECT owner_user_id FROM groups WHERE id = $1', [shared])).rows[0]!.owner_user_id).toBe(friend);
    expect((await pool.query('SELECT 1 FROM groups WHERE id = $1', [alone])).rowCount).toBe(0);
    const audit = await pool.query("SELECT actor_user_id FROM audit_logs WHERE action = 'test.by_person'");
    expect(audit.rows[0].actor_user_id).toBeNull(); // the entry stays, without the account link
  });

  it('the database refuses to delete an account whose incidents still identify it (no silent cascade or orphan)', async () => {
    const now = new Date();
    const person = await user('Person');
    await closedSos(person, responder, daysAgo(now, 1));
    await expect(pool.query('DELETE FROM users WHERE id = $1', [person])).rejects.toMatchObject({ code: '23514' });
    expect((await pool.query('SELECT 1 FROM sos_events WHERE user_id = $1', [person])).rowCount).toBe(1);
  });
});
