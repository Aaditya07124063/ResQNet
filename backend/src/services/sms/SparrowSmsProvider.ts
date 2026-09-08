import type { SmsProvider } from './SmsProvider';

// Sparrow SMS (https://docs.sparrowsms.com/, cross-referenced against
// https://sparrowsms.com/blog/send-sms-with-sparrow-api/ and
// https://github.com/sparrowsms/apidocs) — chosen as ResQNet's first real
// SMS adapter: direct domestic connectivity to all four Nepali carriers
// (Nepal Telecom, Ncell, United Telecom, Smart Telecom), ResQNet's primary
// user base, and no TRAI-DLT-style template/registration bureaucracy
// (unlike the India-centric alternatives researched alongside it —
// MSG91/2Factor/SMSCountry — where unregistered senders are silently
// dropped network-side).
//
// NOT VERIFIED against a real send yet (per this phase's explicit "do not
// send real SMS" instruction) — the `to` field's exact accepted shape
// (bare 10-digit local vs. a 977-prefixed form) is inferred from docs, not
// confirmed live; see the final report's "live testing" section.
const SPARROW_API_ENDPOINT = 'https://api.sparrowsms.com/v2/sms/';

interface SparrowSuccessResponse {
  count: number;
  response_code: number;
  response: string;
}

interface SparrowErrorResponse {
  response_code: number;
  response: string;
}

export interface SparrowSmsCredentials {
  /** Sparrow API token — the ONLY secret field; lives in
   * sms_providers.encrypted_credentials, decrypted just-in-time by
   * smsService.ts. Never logged, never included in a thrown error message. */
  token: string;
}

export interface SparrowSmsConfiguration {
  /** Sparrow Sender ID — public (it appears in the delivered SMS itself),
   * so this lives in sms_providers.configuration (plain JSONB), not the
   * encrypted blob. Must be pre-approved in the Sparrow dashboard. */
  from: string;
}

/** Sparrow's documented API expects a bare 10-digit Nepali local number,
 * not E.164 — our verification/session layer works in E.164 throughout, so
 * this adapter strips the country code at the boundary. Defensive/tolerant
 * of "+977", "977", or an already-bare number, since ResQNet is Nepal-only
 * for this provider. */
function toSparrowLocalFormat(e164: string): string {
  const digitsOnly = e164.replace(/[^\d]/g, '');
  if (digitsOnly.startsWith('977') && digitsOnly.length > 10) {
    return digitsOnly.slice(3);
  }
  return digitsOnly;
}

export class SparrowSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: SparrowSmsCredentials,
    private readonly configuration: SparrowSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const body = new URLSearchParams({
      token: this.credentials.token,
      from: this.configuration.from,
      to: toSparrowLocalFormat(to),
      text: message,
    });

    let response: Response;
    try {
      response = await fetch(SPARROW_API_ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body,
      });
    } catch {
      // Network-level failure — never include `body`/credentials in the
      // thrown error (it would otherwise carry the API token).
      throw new Error('Sparrow SMS: network request failed');
    }

    let parsed: SparrowSuccessResponse | SparrowErrorResponse;
    try {
      parsed = (await response.json()) as SparrowSuccessResponse | SparrowErrorResponse;
    } catch {
      throw new Error(`Sparrow SMS: non-JSON response (HTTP ${response.status})`);
    }

    if (!response.ok || parsed.response_code !== 200) {
      // Sparrow's documented error codes (1002 invalid token, 1008 invalid
      // sender, 1011 no valid receiver, 1013 insufficient credits) are
      // safe to surface — they're provider-side status codes, not secrets.
      throw new Error(`Sparrow SMS send failed: ${parsed.response_code} ${parsed.response}`);
    }

    return {};
  }
}
