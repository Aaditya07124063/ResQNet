import { generateKeyPairSync, sign as cryptoSign } from 'crypto';

jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));
jest.mock('../src/services/sosFanOutService', () => ({
  runFanOutAndNotify: jest.fn(),
}));

import { pool } from '../src/database/pool';
import { runFanOutAndNotify } from '../src/services/sosFanOutService';
import {
  getDeviceKey,
  listDeviceKeys,
  reconcilePendingOriginEvents,
  registerDeviceKey,
  revokeDeviceKey,
} from '../src/services/deviceKeyService';
import { buildSignableBytes, type SignableOriginFields } from '../src/utils/originSignature';

const mockedQuery = pool.query as jest.Mock;
const mockedFanOut = runFanOutAndNotify as jest.Mock;

function generateP256KeyPair() {
  return generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
}

function signFields(privateKeyPem: string, fields: SignableOriginFields): string {
  return cryptoSign('sha256', buildSignableBytes(fields), { key: privateKeyPem, dsaEncoding: 'der' }).toString('base64');
}

function fakeDeviceKeyRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'dk-1',
    user_id: 'user-1',
    device_id: 'device-1',
    key_id: 'key-1',
    public_key: 'pem',
    algorithm: 'ECDSA_P256_SHA256',
    registered_at: new Date('2026-01-01T00:00:00Z'),
    revoked_at: null,
    ...overrides,
  };
}

beforeEach(() => jest.clearAllMocks());

describe('registerDeviceKey', () => {
  const { publicKey } = generateP256KeyPair();
  const INPUT = { deviceId: 'device-1', keyId: 'key-1', publicKey, algorithm: 'ECDSA_P256_SHA256' as const };

  it('rejects invalid public key material before ever touching the database', async () => {
    await expect(
      registerDeviceKey('user-1', { ...INPUT, publicKey: 'not a real key' }),
    ).rejects.toMatchObject({ status: 400 });
    expect(mockedQuery).not.toHaveBeenCalled();
  });

  it('inserts/upserts on (device_id, key_id) and returns the public shape (never echoing the public key back)', async () => {
    mockedQuery
      .mockResolvedValueOnce({ rows: [fakeDeviceKeyRow({ public_key: publicKey })] }) // INSERT ... ON CONFLICT
      .mockResolvedValueOnce({ rows: [] }); // reconciliation scan — nothing pending

    const result = await registerDeviceKey('user-1', INPUT);

    expect(mockedQuery.mock.calls[0][0]).toMatch(/ON CONFLICT \(device_id, key_id\)/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['user-1', 'device-1', 'key-1', publicKey, 'ECDSA_P256_SHA256']);
    expect(result.deviceKey).not.toHaveProperty('publicKey');
    expect(result.deviceKey.deviceId).toBe('device-1');
    expect(result.reconciledEventCount).toBe(0);
  });

  it('refuses to attach an existing (device_id, key_id) pair to a different account', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] }); // ON CONFLICT ... WHERE user_id = EXCLUDED.user_id matched nothing
    await expect(registerDeviceKey('user-1', INPUT)).rejects.toMatchObject({ status: 409 });
  });

  it('never fails registration if reconciliation itself throws — the key is still registered', async () => {
    mockedQuery
      .mockResolvedValueOnce({ rows: [fakeDeviceKeyRow({ public_key: publicKey })] })
      .mockRejectedValueOnce(new Error('reconciliation query failed'));

    const result = await registerDeviceKey('user-1', INPUT);

    expect(result.deviceKey.deviceId).toBe('device-1');
    expect(result.reconciledEventCount).toBe(0);
  });
});

describe('listDeviceKeys', () => {
  it('is scoped to the given user id and never includes public_key', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [fakeDeviceKeyRow()] });
    const result = await listDeviceKeys('user-1');
    expect(mockedQuery.mock.calls[0][1]).toEqual(['user-1']);
    expect(result[0]).not.toHaveProperty('publicKey');
  });
});

describe('revokeDeviceKey', () => {
  it('scopes the UPDATE to device id AND owner user id, only touching an active key', async () => {
    mockedQuery.mockResolvedValueOnce({ rowCount: 1 });
    await revokeDeviceKey('user-1', 'device-1');
    expect(mockedQuery.mock.calls[0][0]).toMatch(/UPDATE device_keys SET revoked_at = now\(\)/);
    expect(mockedQuery.mock.calls[0][1]).toEqual(['device-1', 'user-1']);
  });

  it('404s the same way whether the key does not exist, belongs to someone else, or is already revoked', async () => {
    mockedQuery.mockResolvedValueOnce({ rowCount: 0 });
    await expect(revokeDeviceKey('user-1', 'someone-elses-device')).rejects.toMatchObject({ status: 404 });
  });
});

describe('getDeviceKey', () => {
  it('returns null when no key is registered for this (deviceId, keyId) — the unregistered-origin case', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    const result = await getDeviceKey('device-1', 'key-1');
    expect(result).toBeNull();
  });

  it('returns the record, including revokedAt, when found', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [fakeDeviceKeyRow({ revoked_at: new Date('2026-02-01T00:00:00Z') })] });
    const result = await getDeviceKey('device-1', 'key-1');
    expect(result).toMatchObject({ userId: 'user-1', revokedAt: '2026-02-01T00:00:00.000Z' });
  });
});

describe('reconcilePendingOriginEvents', () => {
  const { publicKey, privateKey } = generateP256KeyPair();
  const fields: SignableOriginFields = {
    protocolVersion: '1',
    eventId: 'event-1',
    originDeviceId: 'device-1',
    eventType: 'sos',
    eventSource: 'manual',
    category: 'medical',
    message: 'help',
    latitude: '12.345600',
    longitude: '77.654300',
    locationAccuracyM: '',
    createdAt: '2026-01-01T00:00:00.000Z',
    expiresAt: '2026-01-01T00:10:00.000Z',
    maxHops: '5',
    priority: 'critical',
  };
  const validSignature = signFields(privateKey, fields);

  function pendingEventRow(overrides: Record<string, unknown> = {}) {
    return {
      id: 'sos-row-1',
      event_id: 'event-1',
      user_id: null,
      origin_device_id: 'device-1',
      origin_key_id: 'key-1',
      origin_signature: validSignature,
      origin_verification_state: 'unverified_unregistered',
      origin_envelope_raw: { ...fields, originClaimedUserId: null, keyId: 'key-1', signature: validSignature },
      ...overrides,
    };
  }

  it('promotes a pending event to verified and backfills user_id when the signature validates against the newly registered key', async () => {
    mockedQuery
      .mockResolvedValueOnce({ rows: [pendingEventRow()] }) // SELECT pending
      .mockResolvedValueOnce({ rows: [pendingEventRow({ user_id: 'user-1', origin_verification_state: 'verified' })] }); // UPDATE ... RETURNING

    const count = await reconcilePendingOriginEvents('device-1', 'key-1', publicKey, 'user-1');

    expect(count).toBe(1);
    expect(mockedQuery.mock.calls[1][0]).toMatch(/UPDATE sos_events SET user_id = \$1, origin_verification_state = 'verified'/);
    expect(mockedQuery.mock.calls[1][1]).toEqual(['user-1', 'sos-row-1']);
    expect(mockedFanOut).toHaveBeenCalledTimes(1);
    expect(mockedFanOut.mock.calls[0][1]).toBe('user-1');
  });

  it('never promotes an event whose stored signature does not verify against this key (a forged claim can never graduate)', async () => {
    mockedQuery.mockResolvedValueOnce({
      rows: [pendingEventRow({ origin_signature: 'tampered-signature-that-will-not-verify' })],
    });

    const count = await reconcilePendingOriginEvents('device-1', 'key-1', publicKey, 'user-1');

    expect(count).toBe(0);
    expect(mockedQuery).toHaveBeenCalledTimes(1); // SELECT only — no UPDATE attempted
    expect(mockedFanOut).not.toHaveBeenCalled();
  });

  it('skips an event whose envelope keyId does not match the key just registered (rotation must not cross-verify)', async () => {
    mockedQuery.mockResolvedValueOnce({
      rows: [pendingEventRow({ origin_key_id: 'a-different-key', origin_envelope_raw: { ...fields, keyId: 'a-different-key', signature: validSignature } })],
    });

    const count = await reconcilePendingOriginEvents('device-1', 'key-1', publicKey, 'user-1');

    expect(count).toBe(0);
    expect(mockedQuery).toHaveBeenCalledTimes(1);
  });

  it('returns 0 without error when there is nothing pending for this device', async () => {
    mockedQuery.mockResolvedValueOnce({ rows: [] });
    const count = await reconcilePendingOriginEvents('device-1', 'key-1', publicKey, 'user-1');
    expect(count).toBe(0);
    expect(mockedFanOut).not.toHaveBeenCalled();
  });
});
