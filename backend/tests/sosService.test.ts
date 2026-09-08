jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
  withTransaction: jest.fn(),
}));
jest.mock('../src/websocket/wsServer', () => ({
  broadcastToUser: jest.fn(),
}));
jest.mock('../src/services/userService', () => ({
  getUserById: jest.fn(),
}));
jest.mock('../src/services/pushNotificationService', () => ({
  notifyUsersDevices: jest.fn(),
}));
jest.mock('../src/services/nearbyAlertService', () => ({
  findNearbyEligibleUsers: jest.fn(),
  approximateDistanceLabel: jest.requireActual('../src/services/nearbyAlertService').approximateDistanceLabel,
}));
jest.mock('../src/services/deviceKeyService', () => ({
  getDeviceKey: jest.fn(),
}));

import { generateKeyPairSync, sign as cryptoSign } from 'crypto';
import { pool, withTransaction } from '../src/database/pool';
import { broadcastToUser } from '../src/websocket/wsServer';
import { getUserById } from '../src/services/userService';
import { notifyUsersDevices } from '../src/services/pushNotificationService';
import { findNearbyEligibleUsers } from '../src/services/nearbyAlertService';
import { getDeviceKey } from '../src/services/deviceKeyService';
import { createSosEvent, listSosEvents, updateSosEventStatus } from '../src/services/sosService';
import { buildSignableBytes, type SignableOriginFields } from '../src/utils/originSignature';
import type { OriginEnvelopeInput } from '../src/validation/originEnvelopeSchema';

const mockPoolQuery = pool.query as jest.Mock;
const mockWithTransaction = withTransaction as jest.Mock;
const mockBroadcastToUser = broadcastToUser as jest.Mock;
const mockGetUserById = getUserById as jest.Mock;
const mockNotifyUsersDevices = notifyUsersDevices as jest.Mock;
const mockFindNearbyEligibleUsers = findNearbyEligibleUsers as jest.Mock;
const mockGetDeviceKey = getDeviceKey as jest.Mock;

function fakeSosEventRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'event-1',
    event_id: 'client-event-1',
    user_id: 'user-1',
    event_source: 'manual',
    category: 'medical',
    message: 'need help',
    latitude: '12.345600',
    longitude: '77.654300',
    location_accuracy_m: '15.50',
    status: 'open',
    client_created_at: new Date('2026-01-01T00:00:00Z'),
    server_received_at: new Date('2026-01-01T00:00:01Z'),
    resolved_at: null,
    origin_device_id: null,
    origin_key_id: null,
    origin_signature: null,
    origin_claimed_user_id: null,
    origin_verification_state: 'not_applicable',
    origin_envelope_raw: null,
    ...overrides,
  };
}

const INPUT = {
  eventId: 'client-event-1',
  eventSource: 'manual' as const,
  category: 'medical',
  message: 'need help',
  latitude: 12.3456,
  longitude: 77.6543,
  locationAccuracyM: 15.5,
  clientCreatedAt: new Date('2026-01-01T00:00:00Z'),
};

beforeEach(() => {
  jest.clearAllMocks();
  // Default: trusted-contact fan-out finds no contacts, unless a test
  // overrides this.
  mockWithTransaction.mockImplementation(async (work: (client: { query: jest.Mock }) => unknown) =>
    work({ query: jest.fn().mockResolvedValue({ rows: [] }) }),
  );
  // Defaults for the Phase 17 push step — irrelevant to most of these
  // tests, which assert on the SOS event/recipient rows, not push
  // delivery (see sosServicePush.test.ts for push-specific behavior).
  mockGetUserById.mockResolvedValue({ id: 'user-1', displayName: 'Reporter Name' });
  mockNotifyUsersDevices.mockResolvedValue(new Map());
  mockFindNearbyEligibleUsers.mockResolvedValue([]);
});

describe('createSosEvent', () => {
  it('creates an event and returns a fully-parsed shape (numeric strings -> numbers)', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });

    const result = await createSosEvent('user-1', INPUT);

    expect(result).toEqual({
      id: 'event-1',
      eventId: 'client-event-1',
      eventSource: 'manual',
      category: 'medical',
      message: 'need help',
      latitude: 12.3456,
      longitude: 77.6543,
      locationAccuracyM: 15.5,
      status: 'open',
      clientCreatedAt: '2026-01-01T00:00:00.000Z',
      serverReceivedAt: '2026-01-01T00:00:01.000Z',
      resolvedAt: null,
      originVerificationState: 'not_applicable',
    });
  });

  it('fans out to the reporter\'s own trusted contacts as pending SMS recipients, plus a separate push-channel row for contacts who are also ResQNet users', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    const clientQuery = jest
      .fn()
      .mockResolvedValueOnce({
        rows: [
          { contact_user_id: 'contact-user-1', phone_number: '+10000000001' },
          { contact_user_id: null, phone_number: '+10000000002' },
        ],
      })
      .mockResolvedValueOnce({ rows: [] }) // SMS insert, contact-user-1
      .mockResolvedValueOnce({ rows: [{ id: 'push-recipient-1' }] }) // PUSH insert, contact-user-1 (has contact_user_id)
      .mockResolvedValueOnce({ rows: [] }); // SMS insert, contact 2 (no contact_user_id -> no push row)
    mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
      work({ query: clientQuery }),
    );

    await createSosEvent('user-1', INPUT);

    expect(clientQuery).toHaveBeenCalledTimes(4); // 1 select + 2 SMS inserts + 1 push insert
    expect(clientQuery.mock.calls[1]?.[0]).toMatch(/INSERT INTO sos_recipients/);
    expect(clientQuery.mock.calls[1]?.[1]).toEqual(['event-1', 'contact-user-1', '+10000000001']);
    expect(clientQuery.mock.calls[2]?.[0]).toMatch(/'push', 'pending'/);
    expect(clientQuery.mock.calls[2]?.[1]).toEqual(['event-1', 'contact-user-1']);
    expect(clientQuery.mock.calls[3]?.[1]).toEqual(['event-1', null, '+10000000002']);
  });

  it('still returns the successfully-created event even if trusted-contact fan-out throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockWithTransaction.mockRejectedValueOnce(new Error('trusted_contacts lookup failed'));

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
  });

  it('on a retried event_id (unique violation), returns the existing event for the same user rather than erroring', async () => {
    mockPoolQuery
      .mockRejectedValueOnce(
        Object.assign(new Error('duplicate key value violates unique constraint "uq_sos_events_event_id"'), {
          code: '23505',
        }),
      )
      .mockResolvedValueOnce({ rows: [fakeSosEventRow()] });

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
    expect(mockWithTransaction).not.toHaveBeenCalled(); // no re-fan-out on a retry
    expect(mockBroadcastToUser).not.toHaveBeenCalled(); // nothing changed — no spurious realtime event
  });

  it('on a retried event_id belonging to a DIFFERENT user, refuses rather than leaking that event back', async () => {
    mockPoolQuery
      .mockRejectedValueOnce(
        Object.assign(new Error('duplicate key value violates unique constraint "uq_sos_events_event_id"'), {
          code: '23505',
        }),
      )
      .mockResolvedValueOnce({ rows: [fakeSosEventRow({ user_id: 'someone-else' })] });

    await expect(createSosEvent('user-1', INPUT)).rejects.toMatchObject({ status: 409 });
  });

  it('propagates an unrecognized database failure rather than masking it', async () => {
    mockPoolQuery.mockRejectedValueOnce(new Error('connection terminated unexpectedly'));
    await expect(createSosEvent('user-1', INPUT)).rejects.toThrow('connection terminated unexpectedly');
  });

  it('broadcasts sos_created to the reporting user\'s OWN connections only, never any other user', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });

    await createSosEvent('user-1', INPUT);

    expect(mockBroadcastToUser).toHaveBeenCalledTimes(1);
    expect(mockBroadcastToUser.mock.calls[0]?.[0]).toBe('user-1');
    expect(mockBroadcastToUser.mock.calls[0]?.[1]).toMatchObject({ type: 'sos_created', event: { id: 'event-1' } });
  });

  it('still returns the created event even if the realtime broadcast itself throws', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow()] });
    mockBroadcastToUser.mockImplementationOnce(() => {
      throw new Error('socket send failed');
    });

    const result = await createSosEvent('user-1', INPUT);

    expect(result.id).toBe('event-1');
  });
});

describe('listSosEvents', () => {
  it('is scoped to the given user id, newest first', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow(), fakeSosEventRow({ id: 'event-2' })] });

    const result = await listSosEvents('user-1');

    expect(result).toHaveLength(2);
    expect(mockPoolQuery.mock.calls[0]?.[1]).toEqual(['user-1']);
    expect(mockPoolQuery.mock.calls[0]?.[0]).toMatch(/ORDER BY client_created_at DESC/);
  });
});

describe('updateSosEventStatus', () => {
  it('sets resolved_at when transitioning to a terminal status', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow({ status: 'resolved', resolved_at: new Date('2026-01-02T00:00:00Z') })] });

    const result = await updateSosEventStatus('user-1', 'event-1', { status: 'resolved' });

    expect(result.status).toBe('resolved');
    expect(mockPoolQuery.mock.calls[0]?.[1]).toEqual(['resolved', true, 'event-1', 'user-1']);
  });

  it('does not mark resolved_at when transitioning to acknowledged', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow({ status: 'acknowledged' })] });

    await updateSosEventStatus('user-1', 'event-1', { status: 'acknowledged' });

    expect(mockPoolQuery.mock.calls[0]?.[1]).toEqual(['acknowledged', false, 'event-1', 'user-1']);
  });

  it('throws the same 404 whether the event does not exist or belongs to another user', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(updateSosEventStatus('user-1', 'nonexistent', { status: 'resolved' })).rejects.toMatchObject({
      status: 404,
    });
  });

  it('never broadcasts on a failed (404) update', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [] });
    await expect(updateSosEventStatus('user-1', 'nonexistent', { status: 'resolved' })).rejects.toThrow();
    expect(mockBroadcastToUser).not.toHaveBeenCalled();
  });

  it('broadcasts sos_status_updated to the event owner only', async () => {
    mockPoolQuery.mockResolvedValueOnce({ rows: [fakeSosEventRow({ status: 'resolved' })] });

    await updateSosEventStatus('user-1', 'event-1', { status: 'resolved' });

    expect(mockBroadcastToUser).toHaveBeenCalledTimes(1);
    expect(mockBroadcastToUser.mock.calls[0]?.[0]).toBe('user-1');
    expect(mockBroadcastToUser.mock.calls[0]?.[1]).toMatchObject({
      type: 'sos_status_updated',
      event: { status: 'resolved' },
    });
  });
});

describe('createSosEvent — relayed/origin-signed mesh events', () => {
  function generateP256KeyPair() {
    return generateKeyPairSync('ec', {
      namedCurve: 'prime256v1',
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
  }

  const ORIGIN_DEVICE_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const KEY_ID = 'key-fingerprint-1';
  const EVENT_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  const CREATED_AT = '2026-01-01T00:00:00.000Z';
  const EXPIRES_AT = '2099-01-01T00:00:00.000Z'; // far future — never expired in these tests
  const { publicKey, privateKey } = generateP256KeyPair();

  function envelope(overrides: Partial<OriginEnvelopeInput> = {}): OriginEnvelopeInput {
    return {
      protocolVersion: '1',
      originDeviceId: ORIGIN_DEVICE_ID,
      eventType: 'sos',
      eventSource: 'manual',
      category: 'medical',
      message: 'need help',
      latitude: '12.345600',
      longitude: '77.654300',
      locationAccuracyM: '15.50',
      createdAt: CREATED_AT,
      expiresAt: EXPIRES_AT,
      maxHops: 5,
      priority: 'critical',
      originClaimedUserId: null,
      keyId: KEY_ID,
      signature: '', // filled in by signedEnvelope()
      ...overrides,
    };
  }

  function signableFieldsFor(env: OriginEnvelopeInput): SignableOriginFields {
    return {
      protocolVersion: env.protocolVersion,
      eventId: EVENT_ID,
      originDeviceId: env.originDeviceId,
      eventType: env.eventType,
      eventSource: env.eventSource,
      category: env.category,
      message: env.message ?? '',
      latitude: env.latitude ?? '',
      longitude: env.longitude ?? '',
      locationAccuracyM: env.locationAccuracyM ?? '',
      createdAt: env.createdAt,
      expiresAt: env.expiresAt,
      maxHops: String(env.maxHops),
      priority: env.priority,
    };
  }

  function signedEnvelope(overrides: Partial<OriginEnvelopeInput> = {}, signingKey = privateKey): OriginEnvelopeInput {
    const env = envelope(overrides);
    const signature = cryptoSign('sha256', buildSignableBytes(signableFieldsFor(env)), {
      key: signingKey,
      dsaEncoding: 'der',
    }).toString('base64');
    return { ...env, signature };
  }

  const RELAY_UPLOADER_ID = 'relay-device-uploader-user-id'; // deliberately NOT the origin's user id

  /** Top-level request body for the relayed path — eventId + originEnvelope
   * are what actually matter; the other top-level fields are irrelevant
   * once an envelope is present (see sosSchemas.ts), but zod's `.transform`
   * on message/latitude/longitude/locationAccuracyM makes them
   * non-optional-but-nullable in the inferred TS type, so they're supplied
   * as null here to satisfy that type. */
  function relayedRequest(env: OriginEnvelopeInput) {
    return {
      eventId: EVENT_ID,
      message: null,
      latitude: null,
      longitude: null,
      locationAccuracyM: null,
      originEnvelope: env,
    };
  }

  it('attributes a verified event to the ORIGIN device_keys.user_id, never to the uploading relay device\'s own id', async () => {
    mockGetDeviceKey.mockResolvedValueOnce({
      userId: 'origin-user-id',
      deviceId: ORIGIN_DEVICE_ID,
      keyId: KEY_ID,
      publicKey,
      revokedAt: null,
    });
    mockPoolQuery.mockResolvedValueOnce({
      rows: [fakeSosEventRow({ user_id: 'origin-user-id', origin_verification_state: 'verified', origin_device_id: ORIGIN_DEVICE_ID })],
    });
    mockNoTrustedContactsHelper();

    const result = await createSosEvent(RELAY_UPLOADER_ID, relayedRequest(signedEnvelope()));

    expect(result.originVerificationState).toBe('verified');
    // The INSERT's user_id parameter (index 1 of the bound params) must be
    // the ORIGIN's id, never the uploader's.
    expect(mockPoolQuery.mock.calls[0][1][1]).toBe('origin-user-id');
    expect(mockPoolQuery.mock.calls[0][1][1]).not.toBe(RELAY_UPLOADER_ID);
    // Fan-out/self-broadcast runs for the ORIGIN's account, not the relay uploader's.
    expect(mockBroadcastToUser.mock.calls[0]?.[0]).toBe('origin-user-id');
  });

  it('rejects (does not insert anything) when the signature does not verify against the registered key', async () => {
    mockGetDeviceKey.mockResolvedValueOnce({
      userId: 'origin-user-id',
      deviceId: ORIGIN_DEVICE_ID,
      keyId: KEY_ID,
      publicKey,
      revokedAt: null,
    });

    const tamperedEnvelope = { ...signedEnvelope(), category: 'fire' }; // signed for 'medical', claims 'fire'

    await expect(
      createSosEvent(RELAY_UPLOADER_ID, relayedRequest(tamperedEnvelope)),
    ).rejects.toMatchObject({ status: 400 });
    expect(mockPoolQuery).not.toHaveBeenCalled();
  });

  it('rejects when the origin device key has been revoked', async () => {
    mockGetDeviceKey.mockResolvedValueOnce({
      userId: 'origin-user-id',
      deviceId: ORIGIN_DEVICE_ID,
      keyId: KEY_ID,
      publicKey,
      revokedAt: '2026-01-01T00:00:00.000Z',
    });

    await expect(
      createSosEvent(RELAY_UPLOADER_ID, relayedRequest(signedEnvelope())),
    ).rejects.toMatchObject({ status: 403 });
    expect(mockPoolQuery).not.toHaveBeenCalled();
  });

  it('rejects an expired envelope before ever checking the signature or touching the database', async () => {
    await expect(
      createSosEvent(RELAY_UPLOADER_ID, relayedRequest(signedEnvelope({ expiresAt: '2020-01-01T00:00:00.000Z' }))),
    ).rejects.toMatchObject({ status: 400 });
    expect(mockGetDeviceKey).not.toHaveBeenCalled();
    expect(mockPoolQuery).not.toHaveBeenCalled();
  });

  it('preserves an event whose origin device has never registered a key — NULL user_id, unverified state, no fan-out, no account attribution', async () => {
    mockGetDeviceKey.mockResolvedValueOnce(null); // never registered

    mockPoolQuery.mockResolvedValueOnce({
      rows: [
        fakeSosEventRow({
          user_id: null,
          origin_device_id: ORIGIN_DEVICE_ID,
          origin_verification_state: 'unverified_unregistered',
        }),
      ],
    });

    const result = await createSosEvent(
      RELAY_UPLOADER_ID,
      relayedRequest(signedEnvelope({ originClaimedUserId: 'someone-claims-to-be-this-user' })),
    );

    expect(result.originVerificationState).toBe('unverified_unregistered');
    // user_id (bound param index 1) is NULL — never the claimed hint, never the uploader.
    expect(mockPoolQuery.mock.calls[0][1][1]).toBeNull();
    // No identity-dependent fan-out at all: no self-broadcast, no trusted-contact/nearby push.
    expect(mockBroadcastToUser).not.toHaveBeenCalled();
    expect(mockWithTransaction).not.toHaveBeenCalled();
    expect(mockFindNearbyEligibleUsers).not.toHaveBeenCalled();
    expect(mockNotifyUsersDevices).not.toHaveBeenCalled();
  });

  it('on a retried event_id whose origin device matches, returns the existing event rather than erroring', async () => {
    mockGetDeviceKey.mockResolvedValueOnce(null);
    mockPoolQuery
      .mockRejectedValueOnce(Object.assign(new Error('duplicate'), { code: '23505' }))
      .mockResolvedValueOnce({
        rows: [fakeSosEventRow({ user_id: null, origin_device_id: ORIGIN_DEVICE_ID, origin_verification_state: 'unverified_unregistered' })],
      });

    const result = await createSosEvent(RELAY_UPLOADER_ID, relayedRequest(signedEnvelope()));

    expect(result.id).toBe('event-1');
  });

  it('refuses a retried event_id whose origin device does NOT match the stored row (cannot hijack another origin\'s event)', async () => {
    mockGetDeviceKey.mockResolvedValueOnce(null);
    mockPoolQuery
      .mockRejectedValueOnce(Object.assign(new Error('duplicate'), { code: '23505' }))
      .mockResolvedValueOnce({
        rows: [fakeSosEventRow({ user_id: null, origin_device_id: 'a-different-device-id', origin_verification_state: 'unverified_unregistered' })],
      });

    await expect(
      createSosEvent(RELAY_UPLOADER_ID, relayedRequest(signedEnvelope())),
    ).rejects.toMatchObject({ status: 409 });
  });

  function mockNoTrustedContactsHelper() {
    mockWithTransaction.mockImplementationOnce(async (work: (client: { query: jest.Mock }) => unknown) =>
      work({ query: jest.fn().mockResolvedValue({ rows: [] }) }),
    );
  }
});
