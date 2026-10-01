import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { basicAuth, classifyHttpStatus, providerFetch, readJson } from './http';

// Plivo Messages API (https://www.plivo.com/docs/messaging/api/messages):
// JSON POST to Account/{auth_id}/Message/ with HTTP Basic auth; `dst` is
// E.164 with '+'. Success is HTTP 202 with `message_uuid: [...]`. Plivo's
// former India DLT request fields are deprecated, so none are sent.

export interface PlivoSmsCredentials {
  auth_id: string;
  auth_token: string;
}
export interface PlivoSmsConfiguration {
  from: string;
}

export class PlivoSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: PlivoSmsCredentials,
    private readonly configuration: PlivoSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const response = await providerFetch(
      `https://api.plivo.com/v1/Account/${encodeURIComponent(this.credentials.auth_id)}/Message/`,
      {
        method: 'POST',
        headers: {
          authorization: basicAuth(this.credentials.auth_id, this.credentials.auth_token),
          'content-type': 'application/json',
        },
        body: JSON.stringify({ src: this.configuration.from, dst: to, text: message }),
      },
    );
    const body = await readJson<{ message_uuid?: string[] }>(response);
    if (!response.ok) {
      throw new SmsProviderError(classifyHttpStatus(response.status), `Plivo rejected request (HTTP ${response.status})`);
    }
    return { providerMessageId: body?.message_uuid?.[0] };
  }
}
