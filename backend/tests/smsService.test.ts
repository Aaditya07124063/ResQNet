jest.mock('../src/database/pool', () => ({
  pool: { query: jest.fn() },
}));
jest.mock('../src/utils/credentialEncryption', () => ({
  decryptCredentials: jest.fn(),
}));
jest.mock('../src/services/sms/SparrowSmsProvider', () => ({
  SparrowSmsProvider: jest.fn(),
}));

import { pool } from '../src/database/pool';
import { decryptCredentials } from '../src/utils/credentialEncryption';
import { SparrowSmsProvider } from '../src/services/sms/SparrowSmsProvider';
import { sendSms } from '../src/services/sms/smsService';
import { SmsProviderError } from '../src/services/sms/SmsProviderError';

const mockQuery = pool.query as jest.Mock;
const mockDecrypt = decryptCredentials as jest.Mock;
const MockSparrowSmsProvider = SparrowSmsProvider as unknown as jest.Mock;

function providerRow(overrides: Record<string, unknown> = {}) {
  return {
    id: 'provider-1',
    provider_type: 'sparrow_sms',
    display_name: 'Sparrow SMS',
    priority: 100,
    encrypted_credentials: Buffer.from('irrelevant-in-this-mocked-test'),
    configuration: { from: 'ResQNet' },
    ...overrides,
  };
}

describe('smsService.sendSms', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockDecrypt.mockReturnValue({ token: 'decrypted-token' });
  });

  it('throws when no enabled sms_providers row exists', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await expect(sendSms('+9779812345678', 'hi')).rejects.toThrow(/not currently available/);
  });

  it('only selects enabled providers, ordered by priority ascending', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    await expect(sendSms('+9779812345678', 'hi')).rejects.toThrow();
    const [sql] = mockQuery.mock.calls[0];
    expect(sql).toMatch(/enabled = true/);
    expect(sql).toMatch(/ORDER BY priority ASC/);
  });

  it('decrypts credentials and dispatches through the matching adapter', async () => {
    const mockSend = jest.fn().mockResolvedValue({ providerMessageId: 'msg-1' });
    MockSparrowSmsProvider.mockImplementation(() => ({ send: mockSend }));
    mockQuery.mockResolvedValueOnce({ rows: [providerRow()] });

    await sendSms('+9779812345678', 'Your code is 123456');

    expect(mockDecrypt).toHaveBeenCalledWith(Buffer.from('irrelevant-in-this-mocked-test'));
    expect(MockSparrowSmsProvider).toHaveBeenCalledWith({ token: 'decrypted-token' }, { from: 'ResQNet' });
    expect(mockSend).toHaveBeenCalledWith('+9779812345678', 'Your code is 123456');
  });

  it('fails over to the next-priority provider when the first one throws', async () => {
    const failingSend = jest.fn().mockRejectedValue(new Error('provider A down'));
    const succeedingSend = jest.fn().mockResolvedValue({});
    MockSparrowSmsProvider.mockImplementationOnce(() => ({ send: failingSend })).mockImplementationOnce(() => ({
      send: succeedingSend,
    }));
    mockQuery.mockResolvedValueOnce({
      rows: [providerRow({ id: 'a', priority: 1 }), providerRow({ id: 'b', priority: 2 })],
    });

    await sendSms('+9779812345678', 'hi');

    expect(failingSend).toHaveBeenCalledTimes(1);
    expect(succeedingSend).toHaveBeenCalledTimes(1);
  });

  it('throws a generic error (never the underlying provider error) when every provider fails', async () => {
    MockSparrowSmsProvider.mockImplementation(() => ({
      send: jest.fn().mockRejectedValue(new Error('leaked-provider-internal-detail')),
    }));
    mockQuery.mockResolvedValueOnce({ rows: [providerRow()] });

    await expect(sendSms('+9779812345678', 'hi')).rejects.toThrow(/not currently available/);
    try {
      await sendSms('+9779812345678', 'hi');
    } catch (err) {
      expect((err as Error).message).not.toContain('leaked-provider-internal-detail');
    }
  });

  it('throws for an unrecognized provider_type rather than guessing an adapter', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [providerRow({ provider_type: 'unknown_provider' })] });
    await expect(sendSms('+9779812345678', 'hi')).rejects.toThrow(/not currently available/);
  });

  describe('fallback policy', () => {
    beforeEach(() => MockSparrowSmsProvider.mockReset());

    function chain(...sends: jest.Mock[]) {
      for (const send of sends) MockSparrowSmsProvider.mockImplementationOnce(() => ({ send }));
      mockQuery.mockResolvedValueOnce({
        rows: sends.map((_, i) => providerRow({ id: `p${i}`, priority: i + 1 })),
      });
    }

    it('orders ties deterministically by creation time', async () => {
      mockQuery.mockResolvedValueOnce({ rows: [] });
      await expect(sendSms('+9779812345678', 'hi')).rejects.toThrow();
      expect(mockQuery.mock.calls[0][0]).toMatch(/ORDER BY priority ASC, created_at ASC/);
    });

    it('returns which provider accepted the message', async () => {
      chain(jest.fn().mockResolvedValue({ providerMessageId: 'm-1' }));
      await expect(sendSms('+9779812345678', 'hi')).resolves.toEqual({
        providerId: 'p0',
        providerType: 'sparrow_sms',
        providerMessageId: 'm-1',
      });
    });

    it.each(['availability', 'configuration', 'unsupported'] as const)(
      'advances past a %s failure and re-sends the identical message',
      async (kind) => {
        const first = jest.fn().mockRejectedValue(new SmsProviderError(kind, 'x'));
        const second = jest.fn().mockResolvedValue({});
        chain(first, second);

        const result = await sendSms('+9779812345678', 'Your code is 123456');

        expect(result.providerId).toBe('p1');
        expect(second).toHaveBeenCalledWith('+9779812345678', 'Your code is 123456');
      },
    );

    it('stops at a recipient rejection and reports it as a 400', async () => {
      const first = jest.fn().mockRejectedValue(new SmsProviderError('recipient', 'bad number'));
      const second = jest.fn().mockResolvedValue({});
      chain(first, second);

      await expect(sendSms('+9779812345678', 'hi')).rejects.toMatchObject({ status: 400 });
      expect(second).not.toHaveBeenCalled();
    });

    it('stops after the first accepted send (no duplicate deliveries)', async () => {
      const first = jest.fn().mockResolvedValue({});
      const second = jest.fn().mockResolvedValue({});
      chain(first, second);

      await sendSms('+9779812345678', 'hi');
      expect(second).not.toHaveBeenCalled();
    });

    it('tries each enabled provider exactly once before failing', async () => {
      const sends = [1, 2, 3].map(() => jest.fn().mockRejectedValue(new SmsProviderError('availability', 'down')));
      chain(...sends);

      await expect(sendSms('+9779812345678', 'hi')).rejects.toMatchObject({ status: 500 });
      for (const send of sends) expect(send).toHaveBeenCalledTimes(1);
    });

    it('treats an undecryptable credential blob as a configuration failure and moves on', async () => {
      mockDecrypt.mockImplementationOnce(() => {
        throw new Error('auth tag mismatch');
      });
      const second = jest.fn().mockResolvedValue({});
      MockSparrowSmsProvider.mockImplementationOnce(() => ({ send: second }));
      mockQuery.mockResolvedValueOnce({ rows: [providerRow({ id: 'p0' }), providerRow({ id: 'p1', priority: 2 })] });

      await expect(sendSms('+9779812345678', 'hi')).resolves.toMatchObject({ providerId: 'p1' });
    });
  });
});
