import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { classifyHttpStatus, providerFetch, readJson } from './http';

// Sinch SMS REST API (https://developers.sinch.com/docs/sms/api-reference/):
// POST https://{region}.sms.api.sinch.com/xms/v1/{service_plan_id}/batches
// with a per-service-plan Bearer token; body `{from, to: [...], body}`;
// success returns the batch `id`.

export const SINCH_REGIONS = ['us', 'eu', 'au', 'br', 'ca'] as const;
export type SinchRegion = (typeof SINCH_REGIONS)[number];

export interface SinchSmsCredentials {
  api_token: string;
}
export interface SinchSmsConfiguration {
  service_plan_id: string;
  sender: string;
  region?: SinchRegion;
}

export class SinchSmsProvider implements SmsProvider {
  constructor(
    private readonly credentials: SinchSmsCredentials,
    private readonly configuration: SinchSmsConfiguration,
  ) {}

  async send(to: string, message: string): Promise<{ providerMessageId?: string }> {
    // The region is validated against SINCH_REGIONS by the registry schema,
    // so the host can only ever be one of Sinch's own regional endpoints.
    const region = this.configuration.region ?? 'us';
    const response = await providerFetch(
      `https://${region}.sms.api.sinch.com/xms/v1/${encodeURIComponent(this.configuration.service_plan_id)}/batches`,
      {
        method: 'POST',
        headers: { authorization: `Bearer ${this.credentials.api_token}`, 'content-type': 'application/json' },
        body: JSON.stringify({ from: this.configuration.sender, to: [to], body: message }),
      },
    );
    const body = await readJson<{ id?: string }>(response);
    if (!response.ok) {
      throw new SmsProviderError(classifyHttpStatus(response.status), `Sinch rejected request (HTTP ${response.status})`);
    }
    return { providerMessageId: body?.id };
  }
}
