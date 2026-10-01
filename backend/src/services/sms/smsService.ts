import { pool } from '../../database/pool';
import { decryptCredentials } from '../../utils/credentialEncryption';
import { logger } from '../../utils/logger';
import { HttpError } from '../../utils/httpError';
import { createProviderAdapter } from './providerRegistry';
import { SmsProviderError, type SmsFailureKind } from './SmsProviderError';

// Dispatches an outbound SMS through the highest-priority enabled row in
// sms_providers, falling over to the next-priority row on failure — the
// generic "provider system" §U/§V of docs/AUDIT.md describes. Nothing
// outside this file and smsProviderAdminService.ts touches
// encrypted_credentials, and credential decryption happens just-in-time.
//
// Fallback policy (deterministic, see SmsProviderError.ts):
// - providers are tried once each, in ascending priority (ties broken by
//   creation time), so the loop is bounded by the number of enabled rows;
// - the caller's message (and therefore the same OTP code) is re-sent
//   unchanged to the next provider — a fallback never generates a new code;
// - the first accepted send ends the loop, so at most one provider accepts
//   the message under normal operation (a timeout after the provider has
//   already accepted can still produce a duplicate of the same code, which
//   is preferred over failing to deliver an emergency login code);
// - a recipient rejection stops the loop, because every provider would
//   reject the same number.

interface DbSmsProviderRow {
  id: string;
  provider_type: string;
  display_name: string;
  priority: number;
  encrypted_credentials: Buffer;
  configuration: Record<string, unknown> | null;
}

export interface SmsDeliveryResult {
  providerId: string;
  providerType: string;
  providerMessageId?: string;
}

function failureKind(err: unknown): SmsFailureKind {
  // Anything that is not an adapter-classified failure (for example a
  // credential blob that no longer decrypts) is a problem with this
  // provider's stored setup, not with the recipient.
  return err instanceof SmsProviderError ? err.kind : 'configuration';
}

/**
 * Sends `message` to `to` (E.164) via the enabled sms_providers rows, in
 * priority order (ascending — lower number = tried first, matching the
 * idx_sms_providers_enabled_priority index). Returns which provider
 * accepted the message. Throws a generic HttpError on total failure — the
 * underlying provider failure (never containing credentials or message
 * content) is logged server-side only.
 */
export async function sendSms(to: string, message: string): Promise<SmsDeliveryResult> {
  const { rows } = await pool.query<DbSmsProviderRow>(
    `SELECT id, provider_type, display_name, priority, encrypted_credentials, configuration
     FROM sms_providers WHERE enabled = true ORDER BY priority ASC, created_at ASC`,
  );

  if (rows.length === 0) {
    logger.error('sendSms: no enabled sms_providers row configured');
    throw HttpError.internal('SMS delivery is not currently available');
  }

  let lastKind: SmsFailureKind = 'availability';
  for (const row of rows) {
    try {
      const provider = createProviderAdapter(
        row.provider_type,
        decryptCredentials(row.encrypted_credentials),
        row.configuration ?? {},
      );
      const { providerMessageId } = await provider.send(to, message);
      logger.info({ providerId: row.id, providerType: row.provider_type }, 'SMS accepted by provider');
      return { providerId: row.id, providerType: row.provider_type, providerMessageId };
    } catch (err) {
      lastKind = failureKind(err);
      const providerCode = err instanceof SmsProviderError ? err.providerCode : undefined;
      const context = { providerId: row.id, providerType: row.provider_type, failure: lastKind, providerCode };
      if (lastKind === 'unsupported') {
        logger.info(context, 'SMS provider does not serve this destination, trying next provider');
      } else if (lastKind === 'availability') {
        logger.warn(context, 'SMS provider temporarily unavailable, trying next provider');
      } else {
        logger.error(context, 'SMS provider send failed');
      }
      if (err instanceof SmsProviderError && !err.advancesFallback) break;
    }
  }

  logger.error({ failure: lastKind, providersTried: rows.length }, 'SMS delivery failed on every eligible provider');
  if (lastKind === 'recipient') {
    throw HttpError.badRequest('This phone number cannot receive SMS messages');
  }
  throw HttpError.internal('SMS delivery is not currently available');
}
