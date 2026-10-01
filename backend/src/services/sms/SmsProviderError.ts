/**
 * Why a provider send failed. Deliberately coarse so the fallback policy in
 * smsService.ts stays deterministic:
 *
 * - `availability`: temporary — network failure, timeout, rate limit, 5xx,
 *   provider-side credit/throughput exhaustion. The next provider is tried.
 * - `configuration`: this provider's own setup is wrong — rejected
 *   credentials, unapproved sender, invalid template. Another provider has
 *   independent credentials, so the next provider is still tried, but the
 *   failure is logged at error level and surfaced in the admin test result
 *   so it is never silently masked by a working fallback.
 * - `unsupported`: this provider does not deliver to the destination's
 *   country (for example Sparrow SMS outside Nepal). The next provider is
 *   tried; this is expected routing, not an error.
 * - `recipient`: the destination number itself was rejected. Every provider
 *   would reject it, so the fallback chain stops.
 */
export type SmsFailureKind = 'availability' | 'configuration' | 'unsupported' | 'recipient';

/** A provider failure whose message never contains credentials, request
 * bodies, message content, or raw provider responses — only a fixed
 * description plus, at most, the provider's own numeric/status code. */
export class SmsProviderError extends Error {
  constructor(
    public readonly kind: SmsFailureKind,
    message: string,
    /** Provider-documented status/error code, safe to log and display. */
    public readonly providerCode?: string,
  ) {
    super(message);
    this.name = 'SmsProviderError';
  }

  /** True when the failure is temporary for this provider. */
  get retryable(): boolean {
    return this.kind === 'availability';
  }

  /** True when trying the next provider could succeed. */
  get advancesFallback(): boolean {
    return this.kind !== 'recipient';
  }
}
