import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { basicAuth, classifyHttpStatus, providerFetch, readJson, withoutPlus } from './http';

// Vonage Messages API (https://developer.vonage.com/en/messages/overview) —
// Vonage labels the older SMS API (rest.nexmo.com/sms/json) as legacy and
// directs new integrations here. POST /v1/messages with HTTP Basic auth
// (API key + secret), `{message_type: 'text', channel: 'sms', to, from,
// text}` where `to` is E.164 without '+'. Success is HTTP 202 with
// `message_uuid`.
const VONAGE_MESSAGES_ENDPOINT = 'https://api.nexmo.com/v1/messages';

export interface VonageSmsCredentials {
  api_key: string;
  api_secret: string;
}
export interface VonageSmsConfiguration {
  from: string;
}

export class VonageSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: VonageSmsCredentials,
    private readonly configuration: VonageSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const response = await providerFetch(VONAGE_MESSAGES_ENDPOINT, {
      method: 'POST',
      headers: {
        authorization: basicAuth(this.credentials.api_key, this.credentials.api_secret),
        accept: 'application/json',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        message_type: 'text',
        channel: 'sms',
        to: withoutPlus(to),
        from: this.configuration.from,
        text: message,
      }),
    });
    const body = await readJson<{ message_uuid?: string }>(response);
    if (!response.ok) {
      throw new SmsProviderError(classifyHttpStatus(response.status), `Vonage rejected request (HTTP ${response.status})`);
    }
    return { providerMessageId: body?.message_uuid };
  }
}
