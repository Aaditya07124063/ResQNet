import { SmsProviderError, type SmsFailureKind } from './SmsProviderError';

const TIMEOUT_MS = 10_000;

/**
 * Provider HTTP helper. Provider endpoints are fixed https URLs defined by
 * each adapter (never admin-supplied), redirects are refused, and a hard
 * timeout applies. It never includes headers, bodies, or secrets in an
 * error, so callers may safely log the resulting SmsProviderError.
 */
export async function providerFetch(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: 'error' });
  } catch {
    throw new SmsProviderError('availability', 'SMS provider network request failed');
  }
}

/** Parses a JSON response body, returning undefined for empty/non-JSON bodies. */
export async function readJson<T>(response: Response): Promise<T | undefined> {
  try {
    return (await response.json()) as T;
  } catch {
    return undefined;
  }
}

/** Default classification of an HTTP failure status. 408/429/5xx are
 * temporary; 401/403 are credential problems; other 4xx are treated as a
 * configuration problem unless an adapter recognises a recipient error. */
export function classifyHttpStatus(status: number): SmsFailureKind {
  if (status === 408 || status === 429 || status >= 500) return 'availability';
  return 'configuration';
}

export function basicAuth(username: string, password: string): string {
  return `Basic ${Buffer.from(`${username}:${password}`, 'utf8').toString('base64')}`;
}

/** Strips a leading '+' for providers that expect bare international digits. */
export function withoutPlus(e164: string): string {
  return e164.replace(/^\+/, '');
}
