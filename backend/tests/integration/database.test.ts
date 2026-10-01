// Real-PostgreSQL integration tests. Unit tests mock `pool.query` and never
// execute SQL; these run the services' actual queries against a database
// migrated with src/database/migrate.ts.
//
// Opt-in: set RESQNET_INTEGRATION_DB=1 plus PG_HOST/PG_PORT/PG_USER/
// PG_PASSWORD/PG_DATABASE for a THROWAWAY database (all tables are
// truncated). Skipped otherwise, so `npm test` needs no database.
import { generateKeyPairSync, randomUUID, sign as cryptoSign } from 'crypto';
import { pool } from '../../src/database/pool';
import { buildSignableBytes, type SignableOriginFields } from '../../src/utils/originSignature';
import type { OriginEnvelopeInput } from '../../src/validation/originEnvelopeSchema';
import { recordSeismicReport } from '../../src/services/seismicService';
import { addGroupMember, createGroup, getGroup, removeGroupMember, transferGroupOwnership } from '../../src/services/groupService';
import { listConversationsForUser } from '../../src/services/conversationService';
import { createAlert, listActiveAlerts, updateAlert } from '../../src/services/alertService';
import { getDisasterSourceStatus, ingestFromAdapter } from '../../src/services/disasterSources';
import { recordAuditEvent } from '../../src/services/auditLogService';
import { listAuditLogs } from '../../src/services/auditLogQueryService';
import { createSosEvent, updateSosEventStatus } from '../../src/services/sosService';
import { registerDeviceKey } from '../../src/services/deviceKeyService';
import {
  getIncident,
  getIncidentCounts,
  listEligibleResponders,
  listIncidents,
  recordIncidentUpdate,
  type IncidentAction,
  type IncidentActor,
} from '../../src/services/incidentService';
import { requestOtp, verifyOtp } from '../../src/services/verificationService';
import { createSmsProvider, disableSmsProvider, listSmsProviders, updateSmsProvider } from '../../src/services/smsProviderAdminService';

const enabled = process.env.RESQNET_INTEGRATION_DB === '1';
const describeDb = enabled ? describe : describe.skip;

async function user(name: string): Promise<string> {
  const { rows } = await pool.query<{ id: string }>(
    'INSERT INTO users (google_subject, display_name) VALUES ($1, $2) RETURNING id',
    [`g-${randomUUID()}`, name],
  );
  return rows[0]!.id;
}

async function trust(ownerId: string, contactId: string) {
  await pool.query(
    'INSERT INTO trusted_contacts (owner_user_id, contact_user_id, name, phone_number) VALUES ($1, $2, $3, $4)',
    [ownerId, contactId, 'Contact', '+9779812345678'],
  );
}

describeDb('database integration', () => {
  beforeAll(async () => {
    const { rows } = await pool.query<{ tablename: string }>(
      "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'",
    );
    await pool.query(`TRUNCATE ${rows.map((r) => `"${r.tablename}"`).join(', ')} RESTART IDENTITY CASCADE`);
  });

  afterAll(async () => {
    await pool.end();
  });

  it('seismic: three distinct nearby users corroborate once; a fourth does not re-alert', async () => {
    const [a, b, c, d] = await Promise.all(['a', 'b', 'c', 'd'].map(user));
    const at = (dLat: number) => ({ latitude: 27.7172 + dLat, longitude: 85.324, detectorScore: 0.8 });

    expect((await recordSeismicReport(a!, at(0))).corroboratingDeviceCount).toBe(1);
    expect((await recordSeismicReport(a!, at(0.001))).corroboratingDeviceCount).toBe(1); // same user again
    expect((await recordSeismicReport(b!, at(0.01))).corroboratingDeviceCount).toBe(2);
    const third = await recordSeismicReport(c!, at(0.02));
    expect(third).toMatchObject({ corroboratingDeviceCount: 3, corroborated: true, alertSent: true });
    const fourth = await recordSeismicReport(d!, at(0.03));
    expect(fourth).toMatchObject({ corroborated: true, alertSent: false });
    const alerts = await pool.query('SELECT count(*)::int AS n FROM seismic_alerts');
    expect(alerts.rows[0].n).toBe(1);
  });

  it('groups: create, add a trusted contact, list as a group conversation, remove', async () => {
    const owner = await user('Owner');
    const friend = await user('Friend');
    const stranger = await user('Stranger');
    await trust(owner, friend);

    const group = await createGroup(owner, { name: 'Annapurna trek', kind: 'trekking' });
    expect(group).toMatchObject({ myRole: 'owner', memberCount: 1, kind: 'trekking' });

    await addGroupMember(owner, group.id, friend);
    await addGroupMember(owner, group.id, friend); // idempotent
    await expect(addGroupMember(owner, group.id, stranger)).rejects.toMatchObject({ status: 400 });

    const detail = await getGroup(friend, group.id);
    expect(detail.members.map((m) => m.role)).toEqual(['owner', 'member']);

    const conversations = await listConversationsForUser(friend);
    expect(conversations.find((cv) => cv.id === group.conversationId)?.group).toEqual({
      id: group.id,
      name: 'Annapurna trek',
      kind: 'trekking',
    });

    // The owner can't just leave; they hand the group over first.
    await expect(removeGroupMember(owner, group.id, owner)).rejects.toMatchObject({ status: 409 });
    await transferGroupOwnership(owner, group.id, friend);
    expect((await getGroup(friend, group.id)).members.map((m) => [m.userId, m.role])).toEqual([
      [friend, 'owner'],
      [owner, 'admin'],
    ]);
    const owners = await pool.query('SELECT owner_user_id FROM groups WHERE id = $1', [group.id]);
    expect(owners.rows[0].owner_user_id).toBe(friend);
    await removeGroupMember(owner, group.id, owner); // former owner leaves
    await expect(getGroup(owner, group.id)).rejects.toMatchObject({ status: 404 });
    expect((await listConversationsForUser(owner)).some((cv) => cv.id === group.conversationId)).toBe(false);
  });

  it('alerts: create, list active, resolve; adapter upserts by external id', async () => {
    const { rows } = await pool.query<{ id: string }>(
      "INSERT INTO employees (email, display_name, password_hash, role) VALUES ($1, 'Ops', 'x', 'employee') RETURNING id",
      [`ops-${randomUUID()}@example.com`],
    );
    const alert = await createAlert(rows[0]!.id, {
      sourceType: 'official',
      sourceName: 'Test Authority',
      category: 'flood',
      severity: 'warning',
      title: 'Flood warning',
      body: 'River rising',
      latitude: 27.7,
      longitude: 85.3,
      radiusKm: 5,
    });
    expect((await listActiveAlerts()).map((a) => a.id)).toContain(alert.id);
    await updateAlert(alert.id, { status: 'resolved' });
    expect((await listActiveAlerts()).map((a) => a.id)).not.toContain(alert.id);

    const adapter = (title: string) => ({
      sourceName: 'Test Feed',
      sourceType: 'verified_partner' as const,
      fetchAlerts: async () => [
        { externalId: 'feed-1', category: 'landslide' as const, severity: 'watch' as const, title, body: 'b', district: 'Kaski' },
      ],
    });
    await ingestFromAdapter(adapter('First version'));
    await ingestFromAdapter(adapter('Updated version'));
    const fromFeed = (await listActiveAlerts()).filter((a) => a.sourceName === 'Test Feed');
    expect(fromFeed).toHaveLength(1);
    expect(fromFeed[0]).toMatchObject({ title: 'Updated version', sourceType: 'verified_partner', sourceUrl: null });
    expect(Date.now() - Date.parse(fromFeed[0]!.retrievedAt!)).toBeLessThan(60_000);
    expect(alert.retrievedAt).toBeNull(); // portal-issued, not fetched

    await ingestFromAdapter({
      sourceName: 'Public Quake Catalogue',
      sourceType: 'international_public',
      fetchAlerts: async () => [
        {
          externalId: 'q-1', category: 'earthquake' as const, severity: 'info' as const, title: 'M4.8 earthquake',
          body: 'Reported by a public catalogue', latitude: 28.2, longitude: 84.7, radiusKm: 50,
          sourceUrl: 'https://example.org/event/q-1',
        },
        { externalId: 'q-2', category: 'earthquake' as const, severity: 'info' as const, title: 'Bad link',
          body: 'x', district: 'Gorkha', sourceUrl: 'http://example.org/insecure' },
      ],
    });
    const quakes = (await listActiveAlerts()).filter((a) => a.sourceName === 'Public Quake Catalogue');
    expect(quakes).toHaveLength(1); // the non-https item was rejected
    expect(quakes[0]).toMatchObject({ sourceType: 'international_public', sourceUrl: 'https://example.org/event/q-1' });
  });

  it('relayed SOS: attributed to the signing device\'s owner; a second gateway creates no duplicate; resolvable by eventId', async () => {
    const origin = await user('Hiker A');
    const { publicKey, privateKey } = generateKeyPairSync('ec', {
      namedCurve: 'prime256v1',
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const deviceId = randomUUID();
    await registerDeviceKey(origin, { deviceId, keyId: 'k1', publicKey, algorithm: 'ECDSA_P256_SHA256' });

    const eventId = randomUUID();
    const envelope: OriginEnvelopeInput = {
      protocolVersion: '1',
      originDeviceId: deviceId,
      eventType: 'sos',
      eventSource: 'manual',
      category: 'trapped',
      message: 'stuck on trail',
      latitude: '27.717200',
      longitude: '85.324000',
      locationAccuracyM: '12.00',
      createdAt: new Date().toISOString(),
      expiresAt: new Date(Date.now() + 3_600_000).toISOString(),
      maxHops: 8,
      priority: 'critical',
      originClaimedUserId: null,
      keyId: 'k1',
      signature: '',
    };
    const fields: SignableOriginFields = {
      protocolVersion: envelope.protocolVersion,
      eventId,
      originDeviceId: envelope.originDeviceId,
      eventType: envelope.eventType,
      eventSource: envelope.eventSource,
      category: envelope.category,
      message: envelope.message ?? '',
      latitude: envelope.latitude ?? '',
      longitude: envelope.longitude ?? '',
      locationAccuracyM: envelope.locationAccuracyM ?? '',
      createdAt: envelope.createdAt,
      expiresAt: envelope.expiresAt,
      maxHops: String(envelope.maxHops),
      priority: envelope.priority,
    };
    envelope.signature = cryptoSign('sha256', buildSignableBytes(fields), { key: privateKey, dsaEncoding: 'der' }).toString(
      'base64',
    );

    const gatewayE = await user('Gateway E');
    const gatewayF = await user('Gateway F');
    const first = await createSosEvent(gatewayE, { eventId, originEnvelope: envelope } as never);
    const second = await createSosEvent(gatewayF, { eventId, originEnvelope: envelope } as never);

    expect(first.id).toBe(second.id);
    expect(first.originVerificationState).toBe('verified');
    const stored = await pool.query('SELECT user_id, count(*) OVER () AS n FROM sos_events WHERE event_id = $1', [eventId]);
    expect(stored.rows[0].user_id).toBe(origin); // never the gateway
    expect(Number(stored.rows[0].n)).toBe(1);

    const resolved = await updateSosEventStatus(origin, eventId, { status: 'resolved' });
    expect(resolved.status).toBe('resolved');
  });

  it('relayed SOS with a tampered message is rejected', async () => {
    const origin = await user('Hiker B');
    const { publicKey, privateKey } = generateKeyPairSync('ec', {
      namedCurve: 'prime256v1',
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    const deviceId = randomUUID();
    await registerDeviceKey(origin, { deviceId, keyId: 'k2', publicKey, algorithm: 'ECDSA_P256_SHA256' });
    const eventId = randomUUID();
    const createdAt = new Date().toISOString();
    const expiresAt = new Date(Date.now() + 3_600_000).toISOString();
    const signed: SignableOriginFields = {
      protocolVersion: '1', eventId, originDeviceId: deviceId, eventType: 'sos', eventSource: 'manual',
      category: 'medical', message: 'original', latitude: '', longitude: '', locationAccuracyM: '',
      createdAt, expiresAt, maxHops: '8', priority: 'critical',
    };
    const signature = cryptoSign('sha256', buildSignableBytes(signed), { key: privateKey, dsaEncoding: 'der' }).toString('base64');
    const tampered = {
      protocolVersion: '1', originDeviceId: deviceId, eventType: 'sos', eventSource: 'manual', category: 'medical',
      message: 'ALTERED', latitude: null, longitude: null, locationAccuracyM: null, createdAt, expiresAt,
      maxHops: 8, priority: 'critical', originClaimedUserId: null, keyId: 'k2', signature,
    };
    const relay = await user('Relay');
    await expect(createSosEvent(relay, { eventId, originEnvelope: tampered } as never)).rejects.toMatchObject({ status: 400 });
  });

  // ---- Incident / responder workflow -------------------------------------
  async function employee(name: string): Promise<string> {
    const { rows } = await pool.query<{ id: string }>(
      "INSERT INTO employees (email, display_name, password_hash, role) VALUES ($1, $2, 'x', 'employee') RETURNING id",
      [`${name}-${randomUUID()}@example.com`, name],
    );
    return rows[0]!.id;
  }
  const responder = (id: string): IncidentActor => ({ id, role: 'employee', canAssign: false });
  const dispatcher = (id: string): IncidentActor => ({ id, role: 'employee', canAssign: true });
  async function newSos(reporter: string): Promise<string> {
    const sos = await createSosEvent(reporter, {
      eventId: randomUUID(),
      eventSource: 'manual',
      category: 'medical',
      message: 'Leg injury',
      latitude: 27.717245,
      longitude: 85.323961,
      clientCreatedAt: new Date(),
    } as never);
    return sos.id;
  }
  const opsStatus = async (id: string) =>
    (await pool.query<{ ops_status: string }>('SELECT ops_status FROM sos_events WHERE id = $1', [id])).rows[0]!.ops_status;
  const activeIds = async () => (await listIncidents({ scope: 'active', limit: 200 })).incidents.map((i) => i.id);

  it('incidents: the full path is recorded with previous/new state and actor role; the queue hides the exact location', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const id = await newSos(reporter);

    const queued = (await listIncidents()).incidents.find((i) => i.id === id);
    expect(queued).toMatchObject({ opsStatus: 'reported', civilianState: 'active', approximateLatitude: 27.72 });
    expect(JSON.stringify(queued)).not.toContain('27.717245');

    expect(await recordIncidentUpdate(dispatcher(lead), id, { action: 'acknowledged' })).toMatchObject({
      previousState: 'reported',
      newState: 'acknowledged',
    });
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic });
    await recordIncidentUpdate(responder(medic), id, { action: 'en_route' });
    await recordIncidentUpdate(responder(medic), id, { action: 'arrived' });
    await recordIncidentUpdate(responder(medic), id, { action: 'assisting' });
    await recordIncidentUpdate(responder(medic), id, { action: 'note', note: 'Splinted' });
    await recordIncidentUpdate(responder(medic), id, { action: 'resolved' });

    const detail = await getIncident(id, { includeSensitive: true });
    expect(detail).toMatchObject({ opsStatus: 'resolved', civilianState: 'active', assignedEmployeeId: medic, latitude: 27.717245 });
    expect(detail.timeline.map((t) => [t.action, t.previousState, t.newState, t.actorRole])).toEqual([
      ['acknowledged', 'reported', 'acknowledged', 'employee'],
      ['assigned', 'acknowledged', 'assigned', 'employee'],
      ['en_route', 'assigned', 'en_route', 'employee'],
      ['arrived', 'en_route', 'arrived', 'employee'],
      ['assisting', 'arrived', 'assisting', 'employee'],
      ['note', 'assisting', 'assisting', 'employee'],
      ['resolved', 'assisting', 'resolved', 'employee'],
    ]);
    expect(await activeIds()).not.toContain(id);
    expect((await listIncidents({ scope: 'closed', limit: 200 })).incidents.map((i) => i.id)).toContain(id);

    // Without SOS_RESPOND the detail keeps the location approximate and drops the phone number.
    const limited = await getIncident(id, { includeSensitive: false });
    expect(limited).toMatchObject({ includesSensitiveDetails: false, latitude: 27.72, locationAccuracyM: null });
    expect(limited.reporter?.phoneNumber ?? null).toBeNull();
  });

  it('incidents: backward, duplicate, skipped and post-terminal transitions are rejected and change nothing', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const id = await newSos(reporter);
    const invalid = { status: 409, code: 'INVALID_TRANSITION' };

    await expect(recordIncidentUpdate(responder(medic), id, { action: 'en_route' })).rejects.toMatchObject(invalid); // skip
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic });
    await expect(recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic })).rejects.toMatchObject(invalid); // duplicate
    await recordIncidentUpdate(responder(medic), id, { action: 'en_route' });
    await expect(recordIncidentUpdate(responder(medic), id, { action: 'en_route' })).rejects.toMatchObject(invalid); // duplicate
    await recordIncidentUpdate(responder(medic), id, { action: 'arrived' });
    await expect(recordIncidentUpdate(dispatcher(lead), id, { action: 'acknowledged' })).rejects.toMatchObject(invalid); // backward
    await expect(recordIncidentUpdate(dispatcher(lead), id, { action: 'stood_down', note: 'x' })).rejects.toMatchObject(invalid); // on scene
    expect(await opsStatus(id)).toBe('arrived');
    await recordIncidentUpdate(responder(medic), id, { action: 'resolved' });
    for (const action of ['acknowledged', 'en_route', 'arrived', 'assisting', 'resolved'] as const) {
      await expect(recordIncidentUpdate(dispatcher(lead), id, { action })).rejects.toMatchObject(invalid);
    }
    await expect(
      recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: lead }),
    ).rejects.toMatchObject(invalid);
    expect(await opsStatus(id)).toBe('resolved');
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'note', note: 'Follow-up call made' }); // notes still allowed
    const actions = (await getIncident(id, { includeSensitive: true })).timeline.map((t) => t.action);
    expect(actions).toEqual(['assigned', 'en_route', 'arrived', 'resolved', 'note']);
  });

  it('incidents: assigning and standing down need SOS_ASSIGN; on-scene progress is the assignee\'s (or a dispatcher\'s)', async () => {
    const reporter = await user('Reporter');
    const [lead, medic, other] = [await employee('lead'), await employee('medic'), await employee('other')];
    const id = await newSos(reporter);
    const forbidden = { status: 403 };

    await expect(
      recordIncidentUpdate(responder(medic), id, { action: 'assigned', assignedEmployeeId: medic }),
    ).rejects.toMatchObject(forbidden);
    await expect(recordIncidentUpdate(responder(medic), id, { action: 'stood_down', note: 'dup' })).rejects.toMatchObject(forbidden);
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic });
    await expect(recordIncidentUpdate(responder(other), id, { action: 'en_route' })).rejects.toMatchObject(forbidden);
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'en_route' }); // dispatcher records for the medic
    // Reassignment moves the right to record progress.
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: other });
    await expect(recordIncidentUpdate(responder(medic), id, { action: 'en_route' })).rejects.toMatchObject(forbidden);
    await recordIncidentUpdate(responder(other), id, { action: 'en_route' });
    expect(await opsStatus(id)).toBe('en_route');
    const rejected = await pool.query('SELECT count(*)::int AS n FROM sos_incident_updates WHERE sos_event_id = $1', [id]);
    expect(rejected.rows[0].n).toBe(4); // only the four accepted actions were written
  });

  it('incidents: civilian marks safe while assigned — incident stays queued, civilian change is on the timeline', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const id = await newSos(reporter);
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic });

    await updateSosEventStatus(reporter, id, { status: 'resolved' });
    await updateSosEventStatus(reporter, id, { status: 'resolved' }); // repeat: no second timeline entry

    expect(await activeIds()).toContain(id);
    const detail = await getIncident(id, { includeSensitive: true });
    expect(detail).toMatchObject({ opsStatus: 'assigned', civilianState: 'safe', assignedEmployeeId: medic });
    expect(detail.timeline.map((t) => [t.action, t.previousState, t.newState, t.employeeId])).toEqual([
      ['assigned', 'reported', 'assigned', lead],
      ['civilian_state', 'active', 'safe', null],
    ]);
    // The responder decides: confirm and stand down with a reason.
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'stood_down', note: 'Reporter confirmed safe by phone' });
    expect(await activeIds()).not.toContain(id);
  });

  it('incidents: civilian marks safe while a responder is en route — the responder can still arrive and resolve', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const id = await newSos(reporter);
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic });
    await recordIncidentUpdate(responder(medic), id, { action: 'en_route' });

    await updateSosEventStatus(reporter, id, { status: 'resolved' });
    expect(await activeIds()).toContain(id);
    expect(await opsStatus(id)).toBe('en_route');

    await recordIncidentUpdate(responder(medic), id, { action: 'arrived' });
    await recordIncidentUpdate(responder(medic), id, { action: 'resolved', note: 'Checked on scene, no injury' });
    expect(await activeIds()).not.toContain(id);
  });

  it('incidents: cancellation during the workflow — recorded, stays queued, stand-down needs a reason', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const id = await newSos(reporter);
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'acknowledged' });

    await updateSosEventStatus(reporter, id, { status: 'false_alarm' });
    const queued = (await listIncidents({ limit: 200 })).incidents.find((i) => i.id === id);
    expect(queued).toMatchObject({ opsStatus: 'acknowledged', civilianState: 'cancelled' });

    await expect(recordIncidentUpdate(dispatcher(lead), id, { action: 'stood_down' })).rejects.toMatchObject({ status: 400 });
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'stood_down', note: 'Reporter cancelled: false alarm' });
    await expect(
      recordIncidentUpdate(dispatcher(lead), id, { action: 'assigned', assignedEmployeeId: medic }),
    ).rejects.toMatchObject({ code: 'INVALID_TRANSITION' });
    const detail = await getIncident(id, { includeSensitive: true });
    expect(detail.timeline.map((t) => t.action)).toEqual(['acknowledged', 'civilian_state', 'stood_down']);
    expect(detail.opsStatus).toBe('stood_down');
  });

  it('incidents: the database itself rejects invalid assignment state', async () => {
    const reporter = await user('Reporter');
    const lead = await employee('lead');
    const id = await newSos(reporter);
    const check = { code: '23514' }; // check_violation

    await expect(
      pool.query("INSERT INTO sos_incident_updates (sos_event_id, employee_id, action) VALUES ($1, $2, 'assigned')", [id, lead]),
    ).rejects.toMatchObject({ ...check, constraint: 'chk_incident_updates_assignee' });
    await expect(
      pool.query(
        "INSERT INTO sos_incident_updates (sos_event_id, employee_id, action, assigned_employee_id) VALUES ($1, $2, 'en_route', $2)",
        [id, lead],
      ),
    ).rejects.toMatchObject({ ...check, constraint: 'chk_incident_updates_assignee' });
    await expect(
      pool.query("UPDATE sos_events SET ops_status = 'en_route', assigned_employee_id = NULL WHERE id = $1", [id]),
    ).rejects.toMatchObject({ ...check, constraint: 'chk_sos_events_active_assignment' });
    await expect(
      pool.query("INSERT INTO sos_incident_updates (sos_event_id, employee_id, action) VALUES ($1, $2, 'stood_down')", [id, lead]),
    ).rejects.toMatchObject({ ...check, constraint: 'chk_incident_updates_note' });
    await expect(
      pool.query("INSERT INTO sos_incident_updates (sos_event_id, action) VALUES ($1, 'acknowledged')", [id]),
    ).rejects.toMatchObject({ ...check, constraint: 'chk_incident_updates_actor' });

    // History keeps its references: an employee who acted cannot be deleted.
    await recordIncidentUpdate(dispatcher(lead), id, { action: 'acknowledged' });
    await expect(pool.query('DELETE FROM employees WHERE id = $1', [lead])).rejects.toMatchObject({ code: '23503' });
  });

  it('incidents: the queue shows every open state until a responder closes it, and pages without gaps', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const ids: Record<string, string> = {};
    for (const name of ['new', 'acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'safe', 'cancelled', 'resolved', 'stood_down']) {
      ids[name] = await newSos(reporter);
    }
    const step = (id: string, action: IncidentAction, who = medic) =>
      recordIncidentUpdate(action === 'assigned' || action === 'stood_down' || action === 'acknowledged' ? dispatcher(lead) : responder(who), id, {
        action,
        assignedEmployeeId: action === 'assigned' ? medic : undefined,
        note: action === 'stood_down' ? 'Duplicate report' : undefined,
      });
    await step(ids.acknowledged!, 'acknowledged');
    for (const [name, path] of Object.entries({
      assigned: ['assigned'],
      en_route: ['assigned', 'en_route'],
      arrived: ['assigned', 'en_route', 'arrived'],
      assisting: ['assigned', 'en_route', 'arrived', 'assisting'],
      resolved: ['assigned', 'en_route', 'arrived', 'resolved'],
      stood_down: ['stood_down'],
    } as Record<string, IncidentAction[]>)) {
      for (const action of path) await step(ids[name]!, action);
    }
    await updateSosEventStatus(reporter, ids.safe!, { status: 'resolved' });
    await updateSosEventStatus(reporter, ids.cancelled!, { status: 'false_alarm' });

    const active = await activeIds();
    for (const name of ['new', 'acknowledged', 'assigned', 'en_route', 'arrived', 'assisting', 'safe', 'cancelled']) {
      expect(active).toContain(ids[name]);
    }
    expect(active).not.toContain(ids.resolved);
    expect(active).not.toContain(ids.stood_down);

    // Walk the active queue two at a time: every incident exactly once.
    const seen: string[] = [];
    let cursor: string | undefined;
    do {
      const page = await listIncidents({ scope: 'active', limit: 2, cursor });
      expect(page.incidents.length).toBeLessThanOrEqual(2);
      seen.push(...page.incidents.map((i) => i.id));
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    expect(seen).toEqual(active);
    expect(new Set(seen).size).toBe(seen.length);
    await expect(listIncidents({ cursor: 'bm90LWEtY3Vyc29y' })).rejects.toMatchObject({ status: 400 });
  });

  it('portal: counts, eligible responders, filters, and sensitive details withheld without SOS_RESPOND', async () => {
    const reporter = await user('Reporter');
    const [lead, medic] = [await employee('lead'), await employee('medic')];
    const clerk = await employee('clerk'); // no SOS_RESPOND
    await pool.query("INSERT INTO employee_permissions (employee_id, permission) VALUES ($1, 'SOS_RESPOND')", [medic]);
    await pool.query("UPDATE employees SET status = 'disabled' WHERE id = $1", [lead]);
    const before = await getIncidentCounts();
    const id = await newSos(reporter);
    await recordIncidentUpdate(dispatcher(clerk), id, { action: 'assigned', assignedEmployeeId: medic });
    await recordIncidentUpdate(responder(medic), id, { action: 'note', note: 'Suspected fracture' });
    await updateSosEventStatus(reporter, id, { status: 'resolved' });

    const after = await getIncidentCounts();
    expect(after.byResponderState.assigned).toBe(before.byResponderState.assigned + 1);
    expect(after.openButCivilianSafe).toBe(before.openButCivilianSafe + 1);
    expect(Date.parse(after.generatedAt)).not.toBeNaN();

    const responders = await listEligibleResponders();
    const medicRow = responders.find((r) => r.id === medic);
    expect(medicRow).toEqual({ id: medic, displayName: 'medic', role: 'employee', openAssignments: 1 });
    expect(responders.some((r) => r.id === clerk)).toBe(false); // no SOS_RESPOND
    expect(responders.some((r) => r.id === lead)).toBe(false); // disabled

    const filtered = await listIncidents({ civilianState: 'safe', assignee: medic, opsStatus: 'assigned', limit: 200 });
    expect(filtered.incidents.map((i) => i.id)).toEqual([id]);
    expect((await listIncidents({ assignee: 'unassigned', limit: 200 })).incidents.some((i) => i.id === id)).toBe(false);

    const limited = await getIncident(id, { includeSensitive: false });
    expect(limited).toMatchObject({ message: null, includesSensitiveDetails: false, latitude: 27.72 });
    const note = limited.timeline.find((t) => t.action === 'note')!;
    expect(note).toMatchObject({ note: null, noteHidden: true });
    expect(JSON.stringify(limited)).not.toMatch(/Suspected fracture|Leg injury|27\.717245/);
    const full = await getIncident(id, { includeSensitive: true });
    expect(full.timeline.find((t) => t.action === 'note')).toMatchObject({ note: 'Suspected fracture', noteHidden: false });
    expect(full.message).toBe('Leg injury');
  });

  it('opted-in medical details in an SOS are only visible with SOS_RESPOND', async () => {
    const reporter = await user('Reporter');
    const medical = '🚗 VEHICLE CRASH DETECTED — AUTO SOS\nBlood: O+ | Allergies: penicillin';
    const sos = await createSosEvent(reporter, {
      eventId: randomUUID(),
      eventSource: 'crash_detection',
      category: 'rescue',
      message: medical,
      latitude: 27.717245,
      longitude: 85.323961,
      clientCreatedAt: new Date(),
    } as never);

    const monitorView = await getIncident(sos.id, { includeSensitive: false });
    expect(monitorView.message).toBeNull();
    expect(JSON.stringify(monitorView)).not.toMatch(/Blood|penicillin|O\+/);
    const queue = (await listIncidents({ limit: 200 })).incidents.find((i) => i.id === sos.id);
    expect(JSON.stringify(queue)).not.toMatch(/Blood|penicillin/);

    const responderView = await getIncident(sos.id, { includeSensitive: true });
    expect(responderView.message).toBe(medical);
  });

  it('audit log reader: filters, newest first, pages by id, redacts secret-looking metadata', async () => {
    const lead = await employee('auditlead');
    const resourceId = randomUUID();
    for (const n of [1, 2, 3]) {
      await recordAuditEvent({
        actorEmployeeId: lead,
        action: `incident.test${n}`,
        resourceType: 'sos_event',
        resourceId,
        outcome: n === 2 ? 'denied' : 'success',
        metadata: { step: n, accessToken: 'should-not-appear' },
      });
    }
    const first = await listAuditLogs({ resourceId, limit: 2 });
    expect(first.entries.map((e) => e.action)).toEqual(['incident.test3', 'incident.test2']);
    expect(first.entries[0]).toMatchObject({
      actor: { kind: 'employee', id: lead, displayName: 'auditlead', role: 'employee' },
      metadata: { step: 3, accessToken: '[redacted]' },
    });
    const second = await listAuditLogs({ resourceId, limit: 2, before: first.nextBefore! });
    expect(second.entries.map((e) => e.action)).toEqual(['incident.test1']);
    expect(second.nextBefore).toBeNull();
    expect((await listAuditLogs({ resourceId, outcome: 'denied' })).entries.map((e) => e.action)).toEqual(['incident.test2']);
    expect((await listAuditLogs({ resourceId, actionPrefix: 'incident.test_' })).entries).toHaveLength(0); // '_' is literal
    expect(JSON.stringify(first)).not.toContain('should-not-appear');
  });

  it('disaster sources: nothing registered or scheduled; sources seen in stored alerts are listed with retrieval time', async () => {
    const status = await getDisasterSourceStatus();
    expect(status.registered).toEqual([]);
    expect(status.scheduledIngestion).toBe(false);
    const quake = status.observed.find((o) => o.sourceName === 'Public Quake Catalogue');
    expect(quake).toMatchObject({ sourceType: 'international_public', activeAlerts: 1, totalAlerts: 1 });
    expect(Date.parse(quake!.lastRetrievedAt!)).not.toBeNaN();
  });

  it('OTP: stored hashed, cooldown enforced, single use, wrong-code attempts counted', async () => {
    const target = '+9779800000001';
    const { code, attemptId } = await requestOtp({ channel: 'sms', target, purpose: 'login', ipAddress: '127.0.0.1' });
    const row = await pool.query('SELECT code_hash FROM verification_attempts WHERE id = $1', [attemptId]);
    expect(row.rows[0].code_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(row.rows[0].code_hash).not.toContain(code);

    await expect(requestOtp({ channel: 'sms', target, purpose: 'login', ipAddress: null })).rejects.toMatchObject({ status: 429 });

    const wrong = code === '000000' ? '111111' : '000000';
    expect((await verifyOtp({ channel: 'sms', target, purpose: 'login', code: wrong })).outcome).toBe('invalid');
    expect((await verifyOtp({ channel: 'sms', target, purpose: 'login', code })).outcome).toBe('verified');
    expect((await verifyOtp({ channel: 'sms', target, purpose: 'login', code })).outcome).toBe('invalid'); // single use
    const attempts = await pool.query('SELECT attempts FROM verification_attempts WHERE id = $1', [attemptId]);
    expect(attempts.rows[0].attempts).toBe(1);
  });

  it('SMS providers: encrypted at rest, secrets never returned, blank secret keeps the stored one, soft disable', async () => {
    const provider = await createSmsProvider({
      providerType: 'sparrow_sms',
      displayName: 'Sparrow',
      credentials: { token: 'integration-secret-token' },
      configuration: { from: 'ResQNet' },
    });
    const raw = await pool.query('SELECT encrypted_credentials FROM sms_providers WHERE id = $1', [provider.id]);
    expect(Buffer.from(raw.rows[0].encrypted_credentials).toString('utf8')).not.toContain('integration-secret-token');

    await updateSmsProvider(provider.id, { credentials: { token: '' }, enabled: true });
    const listed = await listSmsProviders();
    expect(JSON.stringify(listed)).not.toContain('integration-secret-token');
    expect(listed.providers[0]).toMatchObject({ enabled: true, configuredCredentialFields: ['token'], credentialsReadable: true });

    await disableSmsProvider(provider.id);
    expect((await listSmsProviders()).providers[0]!.enabled).toBe(false);
  });
});
