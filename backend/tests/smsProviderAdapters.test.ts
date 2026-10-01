import { BrevoSmsProvider } from '../src/services/sms/BrevoSmsProvider';
import { TwilioSmsProvider } from '../src/services/sms/TwilioSmsProvider';
import { VonageSmsProvider } from '../src/services/sms/VonageSmsProvider';
import { PlivoSmsProvider } from '../src/services/sms/PlivoSmsProvider';
import { SinchSmsProvider } from '../src/services/sms/SinchSmsProvider';
import { ZohoVoiceSmsProvider, clearZohoTokenCache } from '../src/services/sms/ZohoVoiceSmsProvider';
import { AwsSmsProvider } from '../src/services/sms/AwsSmsProvider';
import { SmsProviderError } from '../src/services/sms/SmsProviderError';

// Contract tests: every provider call is intercepted (no network, no real
// SMS, no credits). They pin the request shape each adapter sends and the
// way provider responses are classified for the fallback chain.

const SECRET = 'super-secret-credential-value';
const TO = '+9779812345678';

function jsonResponse(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers(headers),
    json: async () => body,
  } as unknown as Response;
}

let mockFetch: jest.Mock;
beforeEach(() => {
  mockFetch = jest.fn();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (global as any).fetch = mockFetch;
});

function lastRequest(index = 0): { url: string; init: RequestInit } {
  const [url, init] = mockFetch.mock.calls[index] as [string, RequestInit];
  return { url, init };
}

async function expectFailure(promise: Promise<unknown>, kind: string) {
  const error = await promise.catch((err: unknown) => err);
  expect(error).toBeInstanceOf(SmsProviderError);
  expect((error as SmsProviderError).kind).toBe(kind);
  expect((error as Error).message).not.toContain(SECRET);
  return error as SmsProviderError;
}

describe('provider HTTP safety', () => {
  it('refuses redirects and applies a timeout on every provider request', async () => {
    mockFetch.mockResolvedValue(jsonResponse(201, { messageId: 1 }));
    await new BrevoSmsProvider({ api_key: SECRET }, { sender: 'ResQNet' }).send(TO, 'hi');
    const { init } = lastRequest();
    expect(init.redirect).toBe('error');
    expect(init.signal).toBeDefined();
  });

  it('classifies a network failure as availability without leaking secrets', async () => {
    mockFetch.mockRejectedValue(new Error(`connect failed ${SECRET}`));
    await expectFailure(new BrevoSmsProvider({ api_key: SECRET }, { sender: 'ResQNet' }).send(TO, 'hi'), 'availability');
  });
});

describe('BrevoSmsProvider', () => {
  const provider = () => new BrevoSmsProvider({ api_key: SECRET }, { sender: 'ResQNet' });

  it('sends a transactional SMS with the api-key header', async () => {
    mockFetch.mockResolvedValue(jsonResponse(201, { messageId: 12345 }));
    await expect(provider().send(TO, 'Your code is 123456')).resolves.toEqual({ providerMessageId: '12345' });
    const { url, init } = lastRequest();
    expect(url).toBe('https://api.brevo.com/v3/transactionalSMS/send');
    expect((init.headers as Record<string, string>)['api-key']).toBe(SECRET);
    expect(JSON.parse(init.body as string)).toEqual({
      sender: 'ResQNet',
      recipient: '9779812345678',
      content: 'Your code is 123456',
      type: 'transactional',
    });
  });

  it.each([
    [401, {}, 'configuration'],
    [400, { code: 'not_enough_credits' }, 'availability'],
    [429, {}, 'availability'],
    [503, {}, 'availability'],
  ])('classifies HTTP %s %j as %s', async (status, body, kind) => {
    mockFetch.mockResolvedValue(jsonResponse(status, body));
    await expectFailure(provider().send(TO, 'hi'), kind);
  });
});

describe('TwilioSmsProvider', () => {
  const sid = `AC${'a'.repeat(32)}`;
  const provider = (config: Record<string, string>) => new TwilioSmsProvider({ account_sid: sid, auth_token: SECRET }, config);

  it('posts form fields with Basic auth and prefers the Messaging Service SID', async () => {
    mockFetch.mockResolvedValue(jsonResponse(201, { sid: 'SM1' }));
    await expect(
      provider({ from_number: '+15005550006', messaging_service_sid: `MG${'b'.repeat(32)}` }).send(TO, 'hi'),
    ).resolves.toEqual({ providerMessageId: 'SM1' });
    const { url, init } = lastRequest();
    expect(url).toBe(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`);
    expect((init.headers as Record<string, string>).authorization).toBe(
      `Basic ${Buffer.from(`${sid}:${SECRET}`).toString('base64')}`,
    );
    const form = new URLSearchParams(init.body as URLSearchParams);
    expect(form.get('To')).toBe(TO);
    expect(form.get('MessagingServiceSid')).toBe(`MG${'b'.repeat(32)}`);
    expect(form.get('From')).toBeNull();
  });

  it.each([
    [400, 21211, 'recipient'],
    [400, 21610, 'recipient'],
    [400, 21408, 'unsupported'],
    [401, 20003, 'configuration'],
    [429, 20429, 'availability'],
  ])('classifies HTTP %s code %s as %s', async (status, code, kind) => {
    mockFetch.mockResolvedValue(jsonResponse(status, { code, message: 'x' }));
    const error = await expectFailure(provider({ from_number: '+15005550006' }).send(TO, 'hi'), kind);
    expect(error.providerCode).toBe(String(code));
  });
});

describe('VonageSmsProvider', () => {
  it('uses the Messages API with Basic auth and an E.164 number without +', async () => {
    mockFetch.mockResolvedValue(jsonResponse(202, { message_uuid: 'uuid-1' }));
    const provider = new VonageSmsProvider({ api_key: 'key', api_secret: SECRET }, { from: 'ResQNet' });
    await expect(provider.send(TO, 'hi')).resolves.toEqual({ providerMessageId: 'uuid-1' });
    const { url, init } = lastRequest();
    expect(url).toBe('https://api.nexmo.com/v1/messages');
    expect(JSON.parse(init.body as string)).toEqual({
      message_type: 'text',
      channel: 'sms',
      to: '9779812345678',
      from: 'ResQNet',
      text: 'hi',
    });
  });

  it.each([
    [401, 'configuration'],
    [422, 'configuration'],
    [429, 'availability'],
  ])('classifies HTTP %s as %s', async (status, kind) => {
    mockFetch.mockResolvedValue(jsonResponse(status, {}));
    await expectFailure(new VonageSmsProvider({ api_key: 'k', api_secret: SECRET }, { from: 'R' }).send(TO, 'hi'), kind);
  });
});

describe('PlivoSmsProvider', () => {
  it('posts src/dst/text to the account Message endpoint', async () => {
    mockFetch.mockResolvedValue(jsonResponse(202, { message_uuid: ['m-1'] }));
    const provider = new PlivoSmsProvider({ auth_id: 'MAXXXX', auth_token: SECRET }, { from: 'ResQNet' });
    await expect(provider.send(TO, 'hi')).resolves.toEqual({ providerMessageId: 'm-1' });
    const { url, init } = lastRequest();
    expect(url).toBe('https://api.plivo.com/v1/Account/MAXXXX/Message/');
    expect(JSON.parse(init.body as string)).toEqual({ src: 'ResQNet', dst: TO, text: 'hi' });
  });

  it('classifies a 401 as configuration', async () => {
    mockFetch.mockResolvedValue(jsonResponse(401, {}));
    await expectFailure(new PlivoSmsProvider({ auth_id: 'MA', auth_token: SECRET }, { from: 'R' }).send(TO, 'hi'), 'configuration');
  });
});

describe('SinchSmsProvider', () => {
  it('posts a batch to the configured regional endpoint with a Bearer token', async () => {
    mockFetch.mockResolvedValue(jsonResponse(201, { id: 'batch-1' }));
    const provider = new SinchSmsProvider({ api_token: SECRET }, { service_plan_id: 'plan', sender: 'ResQNet', region: 'eu' });
    await expect(provider.send(TO, 'hi')).resolves.toEqual({ providerMessageId: 'batch-1' });
    const { url, init } = lastRequest();
    expect(url).toBe('https://eu.sms.api.sinch.com/xms/v1/plan/batches');
    expect((init.headers as Record<string, string>).authorization).toBe(`Bearer ${SECRET}`);
    expect(JSON.parse(init.body as string)).toEqual({ from: 'ResQNet', to: [TO], body: 'hi' });
  });
});

describe('ZohoVoiceSmsProvider', () => {
  beforeEach(() => clearZohoTokenCache());
  const credentials = { client_id: 'cid', client_secret: SECRET, refresh_token: 'refresh-secret' };

  it('exchanges the refresh token, then sends with the access token', async () => {
    mockFetch
      .mockResolvedValueOnce(jsonResponse(200, { access_token: 'access-1', expires_in: 3600 }))
      .mockResolvedValueOnce(jsonResponse(200, { status: 'SUCCESS', send: { logid: 'log-1' } }));
    const provider = new ZohoVoiceSmsProvider(credentials, { sender_id: 'ResQNet', data_center: 'in' });

    await expect(provider.send(TO, 'hi')).resolves.toEqual({ providerMessageId: 'log-1' });

    expect(lastRequest(0).url).toBe('https://accounts.zoho.in/oauth/v2/token');
    const tokenForm = new URLSearchParams(lastRequest(0).init.body as URLSearchParams);
    expect(tokenForm.get('grant_type')).toBe('refresh_token');
    const { url, init } = lastRequest(1);
    expect(url).toBe('https://voice.zoho.in/rest/json/v1/sms/send');
    expect((init.headers as Record<string, string>).authorization).toBe('Zoho-oauthtoken access-1');
    expect(JSON.parse(init.body as string)).toEqual({ senderId: 'ResQNet', customerNumber: TO, message: 'hi' });
  });

  it('reuses a cached access token for subsequent sends', async () => {
    mockFetch
      .mockResolvedValueOnce(jsonResponse(200, { access_token: 'access-1', expires_in: 3600 }))
      .mockResolvedValue(jsonResponse(200, { status: 'SUCCESS', send: { logid: 'log' } }));
    const provider = new ZohoVoiceSmsProvider(credentials, { sender_id: 'ResQNet' });
    await provider.send(TO, 'one');
    await provider.send(TO, 'two');
    expect(mockFetch).toHaveBeenCalledTimes(3);
  });

  it('reports a rejected refresh token as a configuration failure', async () => {
    mockFetch.mockResolvedValueOnce(jsonResponse(200, { error: 'invalid_code' }));
    const error = await expectFailure(new ZohoVoiceSmsProvider(credentials, { sender_id: 'R' }).send(TO, 'hi'), 'configuration');
    expect(error.providerCode).toBe('invalid_code');
  });

  it('treats a non-SUCCESS send response as a failure', async () => {
    mockFetch
      .mockResolvedValueOnce(jsonResponse(200, { access_token: 'a', expires_in: 3600 }))
      .mockResolvedValueOnce(jsonResponse(200, { status: 'ERROR', code: 'ZVSMS-4001' }));
    await expectFailure(new ZohoVoiceSmsProvider(credentials, { sender_id: 'R' }).send(TO, 'hi'), 'configuration');
  });
});

describe('AwsSmsProvider', () => {
  const credentials = { access_key_id: 'AKIAEXAMPLEKEY1234', secret_access_key: SECRET };
  const fixedNow = () => new Date('2026-09-26T10:00:00.000Z');

  it('sends a SigV4-signed SendTextMessage request to the regional endpoint', async () => {
    mockFetch.mockResolvedValue(jsonResponse(200, { MessageId: 'aws-1' }));
    const provider = new AwsSmsProvider(credentials, { region: 'ap-south-1', origination_identity: 'ResQNet' }, fixedNow);

    await expect(provider.send(TO, 'hi')).resolves.toEqual({ providerMessageId: 'aws-1' });

    const { url, init } = lastRequest();
    expect(url).toBe('https://sms-voice.ap-south-1.amazonaws.com/');
    const headers = init.headers as Record<string, string>;
    expect(headers['x-amz-target']).toBe('PinpointSMSVoiceV2.SendTextMessage');
    expect(headers['content-type']).toBe('application/x-amz-json-1.0');
    expect(headers['x-amz-date']).toBe('20260926T100000Z');
    expect(headers.authorization).toMatch(
      /^AWS4-HMAC-SHA256 Credential=AKIAEXAMPLEKEY1234\/20260926\/ap-south-1\/sms-voice\/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target, Signature=[0-9a-f]{64}$/,
    );
    expect(headers.authorization).not.toContain(SECRET);
    expect(JSON.parse(init.body as string)).toEqual({
      DestinationPhoneNumber: TO,
      MessageBody: 'hi',
      MessageType: 'TRANSACTIONAL',
      OriginationIdentity: 'ResQNet',
    });
  });

  it('adds India DLT parameters only for +91 destinations', async () => {
    mockFetch.mockResolvedValue(jsonResponse(200, { MessageId: 'aws-2' }));
    const provider = new AwsSmsProvider(
      credentials,
      { region: 'ap-south-1', in_entity_id: 'E1', in_template_id: 'T1' },
      fixedNow,
    );
    await provider.send('+919812345678', 'hi');
    await provider.send(TO, 'hi');
    expect(JSON.parse(lastRequest(0).init.body as string).DestinationCountryParameters).toEqual({
      IN_ENTITY_ID: 'E1',
      IN_TEMPLATE_ID: 'T1',
    });
    expect(JSON.parse(lastRequest(1).init.body as string).DestinationCountryParameters).toBeUndefined();
  });

  it('rejects a region that could redirect the request to another host', async () => {
    await expectFailure(
      new AwsSmsProvider(credentials, { region: 'evil.example.com/x' }, fixedNow).send(TO, 'hi'),
      'configuration',
    );
    expect(mockFetch).not.toHaveBeenCalled();
  });

  it.each([
    ['ThrottlingException', 400, 'availability'],
    ['AccessDeniedException', 400, 'configuration'],
    ['InternalServerException', 500, 'availability'],
  ])('classifies %s as %s', async (type, status, kind) => {
    mockFetch.mockResolvedValue(jsonResponse(status, { __type: type }, { 'x-amzn-errortype': `${type}:http://internal.amazon.com/` }));
    const error = await expectFailure(new AwsSmsProvider(credentials, { region: 'us-east-1' }, fixedNow).send(TO, 'hi'), kind);
    expect(error.providerCode).toBe(type);
  });
});
