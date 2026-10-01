import { pool } from '../database/pool';
import { decryptCredentials, encryptCredentials } from '../utils/credentialEncryption';
import { HttpError } from '../utils/httpError';
import { logger } from '../utils/logger';
import {
  ProviderSettingsError,
  createProviderAdapter,
  getProviderDefinition,
  parseProviderSettings,
  providerCatalog,
} from './sms/providerRegistry';
import { SmsProviderError, type SmsFailureKind } from './sms/SmsProviderError';

// Employee-portal administration of sms_providers rows. Credentials are
// write-only through this service: they are validated, encrypted, and
// stored, but never returned — responses only say WHICH credential fields
// are configured. Configuration (sender IDs, regions, template IDs) is
// non-secret and is returned as stored.

interface Row {
  id: string;
  provider_type: string;
  display_name: string;
  enabled: boolean;
  priority: number;
  encrypted_credentials: Buffer;
  configuration: Record<string, unknown> | null;
  last_tested_at: Date | null;
  last_test_status: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface SmsProviderTestResult {
  status: 'success' | 'failed';
  failure?: SmsFailureKind;
  providerCode?: string;
  message: string;
}

function configuredCredentialFields(row: Row): { fields: string[]; readable: boolean } {
  try {
    const credentials = decryptCredentials(row.encrypted_credentials);
    return {
      fields: Object.entries(credentials)
        .filter(([, value]) => typeof value === 'string' && value.length > 0)
        .map(([key]) => key),
      readable: true,
    };
  } catch {
    // Wrong/missing encryption key or a corrupted blob. Reported as a status
    // (so the admin can re-enter credentials) rather than failing the list.
    return { fields: [], readable: false };
  }
}

function publicRow(row: Row) {
  const definition = getProviderDefinition(row.provider_type);
  const credentials = configuredCredentialFields(row);
  return {
    id: row.id,
    providerType: row.provider_type,
    displayName: row.display_name,
    enabled: row.enabled,
    priority: row.priority,
    available: definition?.status === 'available',
    configuration: row.configuration ?? {},
    configuredCredentialFields: credentials.fields,
    credentialsReadable: credentials.readable,
    lastTestedAt: row.last_tested_at?.toISOString() ?? null,
    lastTestStatus: row.last_test_status,
    createdAt: row.created_at.toISOString(),
    updatedAt: row.updated_at.toISOString(),
  };
}

export type PublicSmsProvider = ReturnType<typeof publicRow>;

function validated(type: string, credentials: Record<string, unknown>, configuration: Record<string, unknown>) {
  try {
    return parseProviderSettings(type, credentials, configuration);
  } catch (err) {
    if (err instanceof ProviderSettingsError) {
      // Field names only — submitted values are never echoed back.
      throw HttpError.badRequest(err.message, { fields: err.fields });
    }
    throw err;
  }
}

/** Secret fields left blank on edit keep their stored value. */
function mergeCredentials(existing: Record<string, unknown>, submitted: Record<string, unknown> | undefined) {
  const merged = { ...existing };
  for (const [key, value] of Object.entries(submitted ?? {})) {
    if (typeof value === 'string' && value.trim().length > 0) merged[key] = value.trim();
  }
  return merged;
}

/** Non-secret fields: an empty string or null clears the stored value. */
function mergeConfiguration(existing: Record<string, unknown>, submitted: Record<string, unknown> | undefined) {
  const merged = { ...existing };
  for (const [key, value] of Object.entries(submitted ?? {})) {
    if (value === null || (typeof value === 'string' && value.trim().length === 0)) delete merged[key];
    else merged[key] = typeof value === 'string' ? value.trim() : value;
  }
  return merged;
}

function requireAvailable(type: string): void {
  if (getProviderDefinition(type)?.status !== 'available') {
    throw HttpError.badRequest('This SMS provider is not available for use yet');
  }
}

export async function listSmsProviders() {
  const result = await pool.query<Row>('SELECT * FROM sms_providers ORDER BY priority ASC, created_at ASC');
  return { catalog: providerCatalog(), providers: result.rows.map(publicRow) };
}

export async function createSmsProvider(input: {
  providerType: string;
  displayName: string;
  enabled?: boolean;
  priority?: number;
  credentials: Record<string, unknown>;
  configuration: Record<string, unknown>;
}): Promise<PublicSmsProvider> {
  if (!getProviderDefinition(input.providerType)) throw HttpError.badRequest('Unknown SMS provider type');
  requireAvailable(input.providerType);
  const settings = validated(
    input.providerType,
    mergeCredentials({}, input.credentials),
    mergeConfiguration({}, input.configuration),
  );
  const result = await pool.query<Row>(
    `INSERT INTO sms_providers (provider_type, display_name, enabled, priority, encrypted_credentials, configuration)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [
      input.providerType,
      input.displayName,
      input.enabled ?? false,
      input.priority ?? 100,
      encryptCredentials(settings.credentials),
      JSON.stringify(settings.configuration),
    ],
  );
  return publicRow(result.rows[0]!);
}

export async function updateSmsProvider(
  id: string,
  input: {
    displayName?: string;
    enabled?: boolean;
    priority?: number;
    credentials?: Record<string, unknown>;
    configuration?: Record<string, unknown>;
  },
): Promise<PublicSmsProvider> {
  const existing = await pool.query<Row>('SELECT * FROM sms_providers WHERE id = $1', [id]);
  const row = existing.rows[0];
  if (!row) throw HttpError.notFound('SMS provider not found');

  const settingsChanged = input.credentials !== undefined || input.configuration !== undefined;
  const enabling = input.enabled === true && !row.enabled;
  let encrypted = row.encrypted_credentials;
  let configuration = row.configuration ?? {};

  // Disabling, renaming, or re-prioritising never requires the stored
  // settings to be valid — an admin must always be able to switch off a
  // broken provider. Changing settings, or turning a provider on, does.
  if (settingsChanged || enabling) {
    if (input.enabled ?? row.enabled) requireAvailable(row.provider_type);
    let storedCredentials: Record<string, unknown>;
    try {
      storedCredentials = decryptCredentials(row.encrypted_credentials);
    } catch {
      storedCredentials = {};
    }
    const settings = validated(
      row.provider_type,
      mergeCredentials(storedCredentials, input.credentials),
      mergeConfiguration(configuration, input.configuration),
    );
    if (input.credentials !== undefined) encrypted = encryptCredentials(settings.credentials);
    configuration = settings.configuration;
  }

  const result = await pool.query<Row>(
    `UPDATE sms_providers
     SET display_name = $2, enabled = $3, priority = $4, encrypted_credentials = $5, configuration = $6
     WHERE id = $1 RETURNING *`,
    [
      id,
      input.displayName ?? row.display_name,
      input.enabled ?? row.enabled,
      input.priority ?? row.priority,
      encrypted,
      JSON.stringify(configuration),
    ],
  );
  return publicRow(result.rows[0]!);
}

/** Soft-disable: the row (and its test history) is kept so re-enabling it
 * later does not require re-entering credentials. */
export async function disableSmsProvider(id: string): Promise<void> {
  const result = await pool.query('UPDATE sms_providers SET enabled = false WHERE id = $1', [id]);
  if (!result.rowCount) throw HttpError.notFound('SMS provider not found');
}

const TEST_MESSAGE = 'ResQNet SMS provider test. This message contains no verification code.';

const FAILURE_MESSAGES: Record<SmsFailureKind, string> = {
  availability: 'The provider is temporarily unavailable or rate limited.',
  configuration: 'The provider rejected the credentials or configuration.',
  unsupported: 'The provider does not deliver to this destination country.',
  recipient: 'The provider rejected the destination phone number.',
};

/** Sends one real test SMS through a single provider (enabled or not), with
 * no fallback, and records a classified outcome. */
export async function testSmsProvider(id: string, to: string): Promise<SmsProviderTestResult> {
  const found = await pool.query<Row>('SELECT * FROM sms_providers WHERE id = $1', [id]);
  const row = found.rows[0];
  if (!row) throw HttpError.notFound('SMS provider not found');
  requireAvailable(row.provider_type);

  let result: SmsProviderTestResult;
  try {
    const adapter = createProviderAdapter(
      row.provider_type,
      decryptCredentials(row.encrypted_credentials),
      row.configuration ?? {},
    );
    await adapter.send(to, TEST_MESSAGE);
    result = { status: 'success', message: 'Test message accepted by the provider.' };
  } catch (err) {
    const failure: SmsFailureKind = err instanceof SmsProviderError ? err.kind : 'configuration';
    const providerCode = err instanceof SmsProviderError ? err.providerCode : undefined;
    logger.warn({ providerId: row.id, providerType: row.provider_type, failure, providerCode }, 'SMS provider test failed');
    result = { status: 'failed', failure, providerCode, message: FAILURE_MESSAGES[failure] };
  }

  // last_test_status is VARCHAR(20): 'success' or 'failed_<kind>'.
  await pool.query('UPDATE sms_providers SET last_tested_at = now(), last_test_status = $2 WHERE id = $1', [
    id,
    result.status === 'success' ? 'success' : `failed_${result.failure}`,
  ]);
  return result;
}
