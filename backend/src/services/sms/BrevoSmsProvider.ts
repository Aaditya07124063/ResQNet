import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { classifyHttpStatus, providerFetch, readJson, withoutPlus } from './http';

// Brevo transactional SMS
// (https://developers.brevo.com/reference/send-async-transactional-sms):
// POST /v3/transactionalSMS/send with an `api-key` header; success is
// HTTP 201 with `messageId`; failures carry `{code, message}`.
const BREVO_ENDPOINT = 'https://api.brevo.com/v3/transactionalSMS/send';

export interface BrevoSmsCredentials {
  api_key: string;
}
export interface BrevoSmsConfiguration {
  /** ≤11 alphanumeric or ≤15 numeric characters. */
  sender: string;
}

export class BrevoSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: BrevoSmsCredentials,
    private readonly configuration: BrevoSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const response = await providerFetch(BREVO_ENDPOINT, {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/json', 'api-key': this.credentials.api_key },
      body: JSON.stringify({
        sender: this.configuration.sender,
        recipient: withoutPlus(to),
        content: message,
        type: 'transactional',
      }),
    });
    const body = await readJson<{ messageId?: string | number; code?: string }>(response);
    if (!response.ok) {
      // Running out of SMS credits is an account-level availability problem
      // that another provider can route around.
      const kind = body?.code === 'not_enough_credits' ? 'availability' : classifyHttpStatus(response.status);
      throw new SmsProviderError(kind, `Brevo SMS rejected request (HTTP ${response.status})`, body?.code);
    }
    return { providerMessageId: body?.messageId?.toString() };
  }
}
