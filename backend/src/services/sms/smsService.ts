import { pool } from '../../database/pool';
import { decryptCredentials } from '../../utils/credentialEncryption';
import { logger } from '../../utils/logger';
import { HttpError } from '../../utils/httpError';
import type { SmsProvider } from './SmsProvider';
import { SparrowSmsProvider, type SparrowSmsCredentials, type SparrowSmsConfiguration } from './SparrowSmsProvider';

// Dispatches an outbound SMS through the highest-priority enabled row in
// sms_providers, falling over to the next-priority row on failure — the
// generic "provider system" §U/§V of docs/AUDIT.md describes, with exactly
// one real adapter wired up for now (SparrowSmsProvider — see its own file
// comment for why). Nothing outside this file ever imports a concrete
// provider class or touches encrypted_credentials directly, matching
// "backend must be the only component communicating with the SMS
// provider" and keeping credential decryption in exactly one place.

interface DbSmsProviderRow {
  id: string;
  provider_type: string;
  display_name: string;
  priority: number;
  encrypted_credentials: Buffer;
  configuration: Record<string, unknown> | null;
}

function instantiateProvider(row: DbSmsProviderRow): SmsProvider {
  const credentials = decryptCredentials(row.encrypted_credentials);
  const configuration = row.configuration ?? {};

  switch (row.provider_type) {
    case 'sparrow_sms':
      return new SparrowSmsProvider(
        credentials as unknown as SparrowSmsCredentials,
        configuration as unknown as SparrowSmsConfiguration,
      );
    default:
      // Deliberately generic — a misconfigured provider_type is an admin
      // data-entry error, not something to guess an adapter for.
      throw new Error(`No SMS adapter registered for provider_type "${row.provider_type}"`);
  }
}

/**
 * Sends `message` to `to` (E.164) via the enabled sms_providers row(s), in
 * priority order (ascending — lower number = tried first, matching this
 * table's existing idx_sms_providers_enabled_priority index shape). Tries
 * every enabled provider before giving up. Throws a generic HttpError.internal
 * on total failure — the underlying provider error (which may include
 * provider-side status codes, but never credentials — see each adapter's
 * own comment) is logged server-side only, never surfaced to the API caller.
 */
export async function sendSms(to: string, message: string): Promise<void> {
  const { rows } = await pool.query<DbSmsProviderRow>(
    `SELECT id, provider_type, display_name, priority, encrypted_credentials, configuration
     FROM sms_providers WHERE enabled = true ORDER BY priority ASC`,
  );

  if (rows.length === 0) {
    logger.error('sendSms: no enabled sms_providers row configured');
    throw HttpError.internal('SMS delivery is not currently available');
  }

  let lastError: unknown;
  for (const row of rows) {
    try {
      const provider = instantiateProvider(row);
      await provider.send(to, message);
      return;
    } catch (err) {
      lastError = err;
      // `err` here is safe to log in full: every adapter is required by
      // contract (see SmsProvider.ts) never to throw an error containing
      // its own credentials.
      logger.error(
        { err, providerId: row.id, providerType: row.provider_type },
        'SMS provider send failed, trying next provider',
      );
    }
  }

  logger.error({ err: lastError }, 'All enabled SMS providers failed');
  throw HttpError.internal('SMS delivery is not currently available');
}
