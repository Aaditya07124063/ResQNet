import { createHash } from 'node:crypto';
import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { classifyHttpStatus, providerFetch, readJson } from './http';

// Zoho Voice SMS (https://help.zoho.com/portal/en/kb/zoho-voice/zoho-voice-apis/articles/sms-rest-api):
// JSON POST to /rest/json/v1/sms/send with `Authorization: Zoho-oauthtoken
// <access token>` (scope ZohoVoice.sms.CREATE); body `{senderId,
// customerNumber, message}`; success has `status: 'SUCCESS'` and
// `send.logid`. Zoho OAuth access tokens expire after an hour, so the
// adapter stores a long-lived refresh token (self-client) and exchanges it
// at the Zoho Accounts token endpoint
// (https://www.zoho.com/accounts/protocol/oauth/web-apps/access-token-expiry.html),
// caching the access token in memory until shortly before it expires.
//
// This is Zoho Voice (telephony/SMS) — not Zoho Mail or ZeptoMail, which
// are email products and are not SMS providers.

export const ZOHO_DATA_CENTERS = ['com', 'in', 'eu', 'com.au'] as const;
export type ZohoDataCenter = (typeof ZOHO_DATA_CENTERS)[number];

export interface ZohoVoiceSmsCredentials {
  client_id: string;
  client_secret: string;
  refresh_token: string;
}
export interface ZohoVoiceSmsConfiguration {
  sender_id: string;
  data_center?: ZohoDataCenter;
}

interface CachedToken {
  accessToken: string;
  expiresAt: number;
}

const EXPIRY_MARGIN_MS = 60_000;
const tokenCache = new Map<string, CachedToken>();

/** Test hook — tokens are otherwise cached for the process lifetime. */
export function clearZohoTokenCache(): void {
  tokenCache.clear();
}

export class ZohoVoiceSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: ZohoVoiceSmsCredentials,
    private readonly configuration: ZohoVoiceSmsConfiguration,
  ) {}

  private get dataCenter(): ZohoDataCenter {
    return this.configuration.data_center ?? 'com';
  }

  private cacheKey(): string {
    // Keyed by a digest, so the cache never holds the refresh token itself
    // as a map key.
    return createHash('sha256')
      .update(`${this.dataCenter}\n${this.credentials.client_id}\n${this.credentials.refresh_token}`)
      .digest('hex');
  }

  private async accessToken(): Promise<string> {
    const key = this.cacheKey();
    const cached = tokenCache.get(key);
    if (cached && cached.expiresAt - EXPIRY_MARGIN_MS > Date.now()) return cached.accessToken;

    const response = await providerFetch(`https://accounts.zoho.${this.dataCenter}/oauth/v2/token`, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        refresh_token: this.credentials.refresh_token,
        client_id: this.credentials.client_id,
        client_secret: this.credentials.client_secret,
        grant_type: 'refresh_token',
      }),
    });
    const body = await readJson<{ access_token?: string; expires_in?: number; error?: string }>(response);
    if (!response.ok || !body?.access_token) {
      throw new SmsProviderError(
        response.ok ? 'configuration' : classifyHttpStatus(response.status),
        `Zoho OAuth token refresh failed (HTTP ${response.status})`,
        body?.error,
      );
    }
    tokenCache.set(key, {
      accessToken: body.access_token,
      expiresAt: Date.now() + (body.expires_in ?? 3600) * 1000,
    });
    return body.access_token;
  }

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    const token = await this.accessToken();
    const response = await providerFetch(`https://voice.zoho.${this.dataCenter}/rest/json/v1/sms/send`, {
      method: 'POST',
      headers: { authorization: `Zoho-oauthtoken ${token}`, accept: 'application/json', 'content-type': 'application/json' },
      body: JSON.stringify({ senderId: this.configuration.sender_id, customerNumber: to, message }),
    });
    const body = await readJson<{ status?: string; code?: string; send?: { logid?: string } }>(response);
    if (!response.ok || body?.status !== 'SUCCESS') {
      // A rejected token must be re-fetched on the next attempt.
      if (response.status === 401) tokenCache.delete(this.cacheKey());
      throw new SmsProviderError(
        response.ok ? 'configuration' : classifyHttpStatus(response.status),
        `Zoho Voice rejected request (HTTP ${response.status})`,
        body?.code,
      );
    }
    return { providerMessageId: body.send?.logid };
  }
}
