import type { SmsProvider } from './SmsProvider';
import { SmsProviderError, type SmsFailureKind } from './SmsProviderError';
import { basicAuth, classifyHttpStatus, providerFetch, readJson } from './http';

// Twilio Programmable Messaging
// (https://www.twilio.com/docs/messaging/api/message-resource): form-encoded
// POST to Accounts/{AccountSid}/Messages.json with HTTP Basic auth
// (Account SID + Auth Token); exactly one of From / MessagingServiceSid.
// Success is HTTP 201 with `sid`; errors are `{code, message, status}`.

export interface TwilioSmsCredentials {
  account_sid: string;
  auth_token: string;
}
export interface TwilioSmsConfiguration {
  from_number?: string;
  messaging_service_sid?: string;
}

// https://www.twilio.com/docs/api/errors
function classifyTwilioError(code: number | undefined, status: number): SmsFailureKind {
  switch (code) {
    case 21211: // invalid 'To' number
    case 21614: // 'To' is not a mobile number
    case 21610: // recipient has opted out (STOP)
      return 'recipient';
    case 21408: // geo permission for the destination region not enabled
      return 'unsupported';
    case 20429: // too many requests
      return 'availability';
    default:
      return classifyHttpStatus(status);
  }
}

export class TwilioSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: TwilioSmsCredentials,
    private readonly configuration: TwilioSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const fields: Record<string, string> = { To: to, Body: message };
    if (this.configuration.messaging_service_sid) fields.MessagingServiceSid = this.configuration.messaging_service_sid;
    else if (this.configuration.from_number) fields.From = this.configuration.from_number;
    else throw new SmsProviderError('configuration', 'Twilio sender is not configured');

    const response = await providerFetch(
      `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(this.credentials.account_sid)}/Messages.json`,
      {
        method: 'POST',
        headers: {
          authorization: basicAuth(this.credentials.account_sid, this.credentials.auth_token),
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams(fields),
      },
    );
    const body = await readJson<{ sid?: string; code?: number }>(response);
    if (!response.ok) {
      throw new SmsProviderError(
        classifyTwilioError(body?.code, response.status),
        `Twilio rejected request (HTTP ${response.status})`,
        body?.code !== undefined ? String(body.code) : undefined,
      );
    }
    return { providerMessageId: body?.sid };
  }
}
