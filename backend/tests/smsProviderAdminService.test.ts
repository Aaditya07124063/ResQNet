jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));

import { pool } from '../src/database/pool';
import { decryptCredentials, encryptCredentials } from '../src/utils/credentialEncryption';
import {
  createSmsProvider,
  disableSmsProvider,
  listSmsProviders,
  testSmsProvider,
  updateSmsProvider,
} from '../src/services/smsProviderAdminService';

// Uses the real AES-256-GCM helpers (tests/setupEnv.ts provides a dummy
// key); only the database is mocked.

const mockQuery = pool.query as jest.Mock;
const ID = '22222222-2222-2222-2222-222222222222';
const SECRET = 'sparrow-token-secret';

function row(overrides: Record<string, unknown> = {}) {
  return {
    id: ID,
    provider_type: 'sparrow_sms',
    display_name: 'Sparrow',
    enabled: false,
    priority: 10,
    encrypted_credentials: encryptCredentials({ token: SECRET }),
    configuration: { from: 'ResQNet' },
    last_tested_at: null,
    last_test_status: null,
    created_at: new Date('2026-01-01T00:00:00Z'),
    updated_at: new Date('2026-01-01T00:00:00Z'),
    ...overrides,
  };
}

/** Echoes an UPDATE/INSERT back as the stored row. */
function echoWrite(base: Record<string, unknown>) {
  mockQuery.mockImplementationOnce(async (_sql: string, params: unknown[]) => ({
    rows: [
      row({
        ...base,
        display_name: params[1],
        enabled: params[2],
        priority: params[3],
        encrypted_credentials: params[4],
        configuration: JSON.parse(params[5] as string),
      }),
    ],
  }));
}

beforeEach(() => mockQuery.mockReset());

describe('listSmsProviders', () => {
  it('reports configured credential fields but never credential values', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] });
    const result = await listSmsProviders();
    const serialized = JSON.stringify(result);
    expect(serialized).not.toContain(SECRET);
    expect(serialized).not.toContain('encrypted_credentials');
    expect(result.providers[0]).toMatchObject({ configuredCredentialFields: ['token'], credentialsReadable: true });
    expect(result.catalog.length).toBeGreaterThan(0);
  });

  it('flags an unreadable credential blob instead of failing the whole list', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row({ encrypted_credentials: Buffer.alloc(40) })] });
    const result = await listSmsProviders();
    expect(result.providers[0]).toMatchObject({ credentialsReadable: false, configuredCredentialFields: [] });
  });
});

describe('createSmsProvider', () => {
  it('stores credentials encrypted and defaults to disabled', async () => {
    let stored: Buffer | undefined;
    mockQuery.mockImplementationOnce(async (_sql: string, params: unknown[]) => {
      stored = params[4] as Buffer;
      return { rows: [row({ encrypted_credentials: params[4], enabled: params[2] })] };
    });
    const provider = await createSmsProvider({
      providerType: 'sparrow_sms',
      displayName: 'Sparrow',
      credentials: { token: SECRET },
      configuration: { from: 'ResQNet' },
    });
    expect(stored!.toString('utf8')).not.toContain(SECRET);
    expect(decryptCredentials(stored!)).toEqual({ token: SECRET });
    expect(provider.enabled).toBe(false);
  });

  it('rejects a coming-soon provider', async () => {
    await expect(
      createSmsProvider({ providerType: 'msg91', displayName: 'M', credentials: { authkey: 'k' }, configuration: { template_id: 't' } }),
    ).rejects.toMatchObject({ status: 400 });
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('rejects missing required fields with field names only', async () => {
    await expect(
      createSmsProvider({ providerType: 'sparrow_sms', displayName: 'S', credentials: {}, configuration: { from: 'R' } }),
    ).rejects.toMatchObject({ status: 400, details: { fields: ['credentials.token'] } });
  });
});

describe('updateSmsProvider', () => {
  it('keeps the stored secret when the submitted secret is blank', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] });
    echoWrite({});
    await updateSmsProvider(ID, { credentials: { token: '' }, configuration: { from: 'NewSender' } });
    const params = mockQuery.mock.calls[1][1] as unknown[];
    expect(decryptCredentials(params[4] as Buffer)).toEqual({ token: SECRET });
    expect(JSON.parse(params[5] as string)).toEqual({ from: 'NewSender' });
  });

  it('replaces the secret when a new value is entered', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] });
    echoWrite({});
    await updateSmsProvider(ID, { credentials: { token: 'new-token' } });
    const params = mockQuery.mock.calls[1][1] as unknown[];
    expect(decryptCredentials(params[4] as Buffer)).toEqual({ token: 'new-token' });
  });

  it('clears an optional configuration field set to null', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [
        row({
          provider_type: 'twilio',
          encrypted_credentials: encryptCredentials({ account_sid: `AC${'a'.repeat(32)}`, auth_token: 't' }),
          configuration: { from_number: '+15005550006', messaging_service_sid: `MG${'b'.repeat(32)}` },
        }),
      ],
    });
    echoWrite({ provider_type: 'twilio' });
    await updateSmsProvider(ID, { configuration: { messaging_service_sid: null } });
    expect(JSON.parse((mockQuery.mock.calls[1][1] as unknown[])[5] as string)).toEqual({ from_number: '+15005550006' });
  });

  it('always allows disabling, even when stored settings are unreadable', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row({ enabled: true, encrypted_credentials: Buffer.alloc(40) })] });
    echoWrite({});
    const provider = await updateSmsProvider(ID, { enabled: false });
    expect(provider.enabled).toBe(false);
  });

  it('refuses to enable a provider whose stored settings are invalid', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row({ configuration: {} })] });
    await expect(updateSmsProvider(ID, { enabled: true })).rejects.toMatchObject({ status: 400 });
    expect(mockQuery).toHaveBeenCalledTimes(1);
  });

  it('404s for an unknown provider', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await expect(updateSmsProvider(ID, { enabled: false })).rejects.toMatchObject({ status: 404 });
  });
});

describe('disableSmsProvider', () => {
  it('soft-disables rather than deleting the row', async () => {
    mockQuery.mockResolvedValueOnce({ rowCount: 1 });
    await disableSmsProvider(ID);
    expect(mockQuery.mock.calls[0][0]).toMatch(/UPDATE sms_providers SET enabled = false/);
  });

  it('404s for an unknown provider', async () => {
    mockQuery.mockResolvedValueOnce({ rowCount: 0 });
    await expect(disableSmsProvider(ID)).rejects.toMatchObject({ status: 404 });
  });
});

describe('testSmsProvider', () => {
  let mockFetch: jest.Mock;
  beforeEach(() => {
    mockFetch = jest.fn();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (global as any).fetch = mockFetch;
  });

  it('sends a code-free test message and records success', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] }).mockResolvedValueOnce({ rowCount: 1 });
    mockFetch.mockResolvedValue({ ok: true, status: 200, json: async () => ({ response_code: 200 }) });

    await expect(testSmsProvider(ID, '+9779812345678')).resolves.toMatchObject({ status: 'success' });
    const sentText = new URLSearchParams(mockFetch.mock.calls[0][1].body as URLSearchParams).get('text');
    expect(sentText).not.toMatch(/\d{6}/);
    expect(mockQuery.mock.calls[1][1]).toEqual([ID, 'success']);
  });

  it('returns a classified, secret-free failure and records it', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [row()] }).mockResolvedValueOnce({ rowCount: 1 });
    mockFetch.mockResolvedValue({ ok: false, status: 403, json: async () => ({ response_code: 1002 }) });

    const result = await testSmsProvider(ID, '+9779812345678');
    expect(result).toMatchObject({ status: 'failed', failure: 'configuration', providerCode: '1002' });
    expect(JSON.stringify(result)).not.toContain(SECRET);
    expect(mockQuery.mock.calls[1][1]).toEqual([ID, 'failed_configuration']);
  });
});
