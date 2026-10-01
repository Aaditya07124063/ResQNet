import { SparrowSmsProvider } from '../src/services/sms/SparrowSmsProvider';
import { SmsProviderError } from '../src/services/sms/SmsProviderError';

const SECRET_TOKEN = 'sparrow-secret-token-should-never-leak';

function makeProvider() {
  return new SparrowSmsProvider({ token: SECRET_TOKEN }, { from: 'ResQNet' });
}

function mockFetchOnce(status: number, jsonBody: unknown) {
  const mockFetch = jest.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: async () => jsonBody,
  } as Response);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (global as any).fetch = mockFetch;
  return mockFetch;
}

describe('SparrowSmsProvider', () => {
  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('sends a POST request to the Sparrow API with the expected params', async () => {
    const mockFetch = mockFetchOnce(200, { count: 1, response_code: 200, response: 'queued' });
    await makeProvider().send('+9779812345678', 'Your code is 123456');

    expect(mockFetch).toHaveBeenCalledTimes(1);
    const [url, init] = mockFetch.mock.calls[0];
    expect(url).toBe('https://api.sparrowsms.com/v2/sms/');
    expect(init.method).toBe('POST');
    const params = new URLSearchParams(init.body as string);
    expect(params.get('token')).toBe(SECRET_TOKEN);
    expect(params.get('from')).toBe('ResQNet');
    expect(params.get('text')).toBe('Your code is 123456');
  });

  it('strips the +977 country code, sending a bare 10-digit local number', async () => {
    const mockFetch = mockFetchOnce(200, { count: 1, response_code: 200, response: 'queued' });
    await makeProvider().send('+9779812345678', 'x');
    const params = new URLSearchParams(mockFetch.mock.calls[0][1].body as string);
    expect(params.get('to')).toBe('9812345678');
  });

  it('resolves successfully on response_code 200', async () => {
    mockFetchOnce(200, { count: 1, response_code: 200, response: 'queued' });
    await expect(makeProvider().send('+9779812345678', 'x')).resolves.toEqual({});
  });

  it('throws on a documented Sparrow error response_code', async () => {
    mockFetchOnce(403, { response_code: 1002, response: 'Invalid Token' });
    await expect(makeProvider().send('+9779812345678', 'x')).rejects.toMatchObject({
      kind: 'configuration',
      providerCode: '1002',
    });
  });

  it.each([
    [1007, 'recipient'],
    [1011, 'recipient'],
    [1013, 'availability'],
  ])('classifies Sparrow response_code %s as %s', async (code, kind) => {
    mockFetchOnce(403, { response_code: code, response: 'error' });
    await expect(makeProvider().send('+9779812345678', 'x')).rejects.toMatchObject({ kind });
  });

  it('reports non-Nepali numbers as unsupported without calling Sparrow', async () => {
    const mockFetch = mockFetchOnce(200, { response_code: 200 });
    const error = await makeProvider().send('+919812345678', 'x').catch((err: unknown) => err);
    expect(error).toBeInstanceOf(SmsProviderError);
    expect((error as SmsProviderError).kind).toBe('unsupported');
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it('throws on a network-level failure without leaking the token', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (global as any).fetch = jest.fn().mockRejectedValue(new Error('ECONNREFUSED'));
    await expect(makeProvider().send('+9779812345678', 'x')).rejects.toThrow(/network request failed/i);
  });

  it('throws on a non-JSON response without leaking the token', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (global as any).fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 502,
      json: async () => {
        throw new Error('not json');
      },
    } as unknown as Response);
    await expect(makeProvider().send('+9779812345678', 'x')).rejects.toMatchObject({ kind: 'availability' });
  });

  it('never includes the API token in any thrown error message', async () => {
    mockFetchOnce(403, { response_code: 1002, response: 'Invalid Token' });
    try {
      await makeProvider().send('+9779812345678', 'x');
      fail('expected send() to throw');
    } catch (err) {
      expect((err as Error).message).not.toContain(SECRET_TOKEN);
    }
  });
});
