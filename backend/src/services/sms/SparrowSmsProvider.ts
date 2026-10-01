import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { classifyHttpStatus, providerFetch, readJson } from './http';

// Sparrow SMS v2 (https://docs.sparrowsms.com/sms/outgoing_sendsms/) —
// direct domestic connectivity to Nepali carriers, ResQNet's primary user
// base, with no DLT-style template registration. Documented contract:
// POST form fields token/from/to/text; `to` is a bare 10-digit Nepali
// mobile number (no country code); success is HTTP 200 with
// response_code 200; failures are HTTP 403 with a numeric response_code.
// Sparrow only delivers to Nepal, so any other destination is reported as
// `unsupported` and the fallback chain moves on to the next provider.
const SPARROW_API_ENDPOINT = 'https://api.sparrowsms.com/v2/sms/';

interface SparrowResponse {
  count?: number;
  response_code?: number;
  response?: string;
}

export interface SparrowSmsCredentials {
  /** Sparrow API token — the ONLY secret field. Never logged. */
  token: string;
}

export interface SparrowSmsConfiguration {
  /** Sparrow Sender ID, pre-approved in the Sparrow dashboard. */
  from: string;
}

/** +977 followed by a 10-digit mobile number → the bare 10 digits Sparrow
 * expects; anything else is not a Nepali mobile number. */
export function toSparrowLocalFormat(e164: string): string | null {
  const match = /^\+977(\d{10})$/.exec(e164.trim());
  return match ? match[1]! : null;
}

// Documented Sparrow codes: 1002 invalid token, 1008 invalid sender
// (configuration); 1007/1011 invalid or no valid receiver (recipient);
// 1012/1013 insufficient credit (availability — another provider can send).
function classifySparrowCode(code: number | undefined, status: number) {
  if (code === 1007 || code === 1011) return 'recipient' as const;
  if (code === 1012 || code === 1013) return 'availability' as const;
  if (code !== undefined && code >= 1000) return 'configuration' as const;
  return classifyHttpStatus(status);
}

export class SparrowSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: SparrowSmsCredentials,
    private readonly configuration: SparrowSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const local = toSparrowLocalFormat(to);
    if (!local) throw new SmsProviderError('unsupported', 'Sparrow SMS only delivers to Nepali mobile numbers');

    const response = await providerFetch(SPARROW_API_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        token: this.credentials.token,
        from: this.configuration.from,
        to: local,
        text: message,
      }),
    });

    const parsed = await readJson<SparrowResponse>(response);
    if (!response.ok || parsed?.response_code !== 200) {
      const code = parsed?.response_code;
      throw new SmsProviderError(
        classifySparrowCode(code, response.status),
        `Sparrow SMS rejected request (HTTP ${response.status})`,
        code !== undefined ? String(code) : undefined,
      );
    }

    // Sparrow does not document a per-message id.
    return {};
  }
}
