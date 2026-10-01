import { z } from 'zod';
import type { SmsProvider } from './SmsProvider';
import { SmsProviderError } from './SmsProviderError';
import { SparrowSmsProvider } from './SparrowSmsProvider';
import { BrevoSmsProvider } from './BrevoSmsProvider';
import { TwilioSmsProvider } from './TwilioSmsProvider';
import { VonageSmsProvider } from './VonageSmsProvider';
import { PlivoSmsProvider } from './PlivoSmsProvider';
import { SINCH_REGIONS, SinchSmsProvider } from './SinchSmsProvider';
import { ZOHO_DATA_CENTERS, ZohoVoiceSmsProvider } from './ZohoVoiceSmsProvider';
import { AWS_REGION_PATTERN, AwsSmsProvider } from './AwsSmsProvider';

// Catalog of SMS providers the employee portal can configure. Each entry
// declares its own credential (secret, encrypted at rest) and configuration
// (non-secret, JSONB) fields, so providers are not forced into one shape.
// In every entry ResQNet generates, stores, and verifies the OTP itself
// (verificationService.ts); providers only deliver the text message.
// See docs/SMS_PROVIDERS.md for per-provider status and caveats.

export type ProviderStatus = 'available' | 'coming_soon';

export interface ProviderField {
  key: string;
  label: string;
  required: boolean;
  /** Secret fields are write-only: never returned by the API. */
  secret: boolean;
  help?: string;
  options?: readonly string[];
}

type Settings = Record<string, unknown>;

export interface ProviderDefinition {
  providerType: string;
  displayName: string;
  channel: 'sms';
  status: ProviderStatus;
  /** Who generates and verifies the code: always ResQNet for available providers. */
  otpModel: 'resqnet';
  docsUrl: string;
  coverage: string;
  notes: string;
  credentialFields: ProviderField[];
  configurationFields: ProviderField[];
  credentials: z.ZodType<Settings>;
  configuration: z.ZodType<Settings>;
  create?: (credentials: Settings, configuration: Settings) => SmsProvider;
}

const text = z.string().trim().min(1).max(512);
const secretField = (key: string, label: string, help?: string): ProviderField => ({
  key,
  label,
  required: true,
  secret: true,
  help,
});
const configField = (
  key: string,
  label: string,
  required: boolean,
  help?: string,
  options?: readonly string[],
): ProviderField => ({ key, label, required, secret: false, help, options });

const definitions: ProviderDefinition[] = [
  {
    providerType: 'sparrow_sms',
    displayName: 'Sparrow SMS',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://docs.sparrowsms.com/sms/outgoing_sendsms/',
    coverage: 'Nepal (+977) mobile numbers only',
    notes: 'Direct routes to Nepali operators. Other countries automatically fall through to the next provider.',
    credentialFields: [secretField('token', 'API token')],
    configurationFields: [configField('from', 'Sender ID', true, 'Must be approved in the Sparrow dashboard')],
    credentials: z.object({ token: text }),
    configuration: z.object({ from: text }),
    create: (c, x) => new SparrowSmsProvider(c as { token: string }, x as { from: string }),
  },
  {
    providerType: 'twilio',
    displayName: 'Twilio',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://www.twilio.com/docs/messaging/api/message-resource',
    coverage: 'Global; destination countries must be enabled in Twilio geo permissions',
    notes: 'India delivery requires Twilio sender/DLT registration in the Twilio console.',
    credentialFields: [secretField('account_sid', 'Account SID'), secretField('auth_token', 'Auth token')],
    configurationFields: [
      configField('from_number', 'From number', false, 'E.164 number or alphanumeric sender. Required unless a Messaging Service SID is set'),
      configField('messaging_service_sid', 'Messaging Service SID', false, 'Takes precedence over the From number'),
    ],
    credentials: z.object({ account_sid: z.string().trim().regex(/^AC[0-9a-fA-F]{32}$/), auth_token: text }),
    configuration: z
      .object({
        from_number: text.optional(),
        messaging_service_sid: z.string().trim().regex(/^MG[0-9a-fA-F]{32}$/).optional(),
      })
      .refine((v) => Boolean(v.from_number || v.messaging_service_sid), {
        message: 'A From number or Messaging Service SID is required',
        path: ['from_number'],
      }),
    create: (c, x) => new TwilioSmsProvider(c as { account_sid: string; auth_token: string }, x as { from_number?: string }),
  },
  {
    providerType: 'vonage',
    displayName: 'Vonage',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://developer.vonage.com/en/messages/overview',
    coverage: 'Global; sender rules vary by country',
    notes: 'Uses the Vonage Messages API (the older SMS API is legacy).',
    credentialFields: [secretField('api_key', 'API key'), secretField('api_secret', 'API secret')],
    configurationFields: [configField('from', 'Sender', true, 'Virtual number or alphanumeric sender ID')],
    credentials: z.object({ api_key: text, api_secret: text }),
    configuration: z.object({ from: text }),
    create: (c, x) => new VonageSmsProvider(c as { api_key: string; api_secret: string }, x as { from: string }),
  },
  {
    providerType: 'plivo',
    displayName: 'Plivo',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://www.plivo.com/docs/messaging/api/messages',
    coverage: 'Global; country-specific sender rules apply',
    notes: 'Plivo no longer accepts per-message India DLT fields.',
    credentialFields: [secretField('auth_id', 'Auth ID'), secretField('auth_token', 'Auth token')],
    configurationFields: [configField('from', 'Source number or sender ID', true)],
    credentials: z.object({ auth_id: text, auth_token: text }),
    configuration: z.object({ from: text }),
    create: (c, x) => new PlivoSmsProvider(c as { auth_id: string; auth_token: string }, x as { from: string }),
  },
  {
    providerType: 'sinch',
    displayName: 'Sinch',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://developers.sinch.com/docs/sms/api-reference/',
    coverage: 'Global',
    notes: 'The region must match the region of the service plan.',
    credentialFields: [secretField('api_token', 'API token')],
    configurationFields: [
      configField('service_plan_id', 'Service plan ID', true),
      configField('sender', 'Sender', true),
      configField('region', 'Region', false, 'Defaults to us', SINCH_REGIONS),
    ],
    credentials: z.object({ api_token: text }),
    configuration: z.object({ service_plan_id: text, sender: text, region: z.enum(SINCH_REGIONS).optional() }),
    create: (c, x) =>
      new SinchSmsProvider(c as { api_token: string }, x as { service_plan_id: string; sender: string }),
  },
  {
    providerType: 'brevo_sms',
    displayName: 'Brevo SMS',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://developers.brevo.com/reference/send-async-transactional-sms',
    coverage: 'Global; India DLT not documented by Brevo',
    notes: 'Transactional SMS type is always used.',
    credentialFields: [secretField('api_key', 'API key')],
    configurationFields: [configField('sender', 'Sender', true, 'Up to 11 alphanumeric or 15 numeric characters')],
    credentials: z.object({ api_key: text }),
    configuration: z.object({
      sender: z.string().trim().regex(/^(?:[A-Za-z0-9 ]{1,11}|\d{1,15})$/, 'Invalid sender'),
    }),
    create: (c, x) => new BrevoSmsProvider(c as { api_key: string }, x as { sender: string }),
  },
  {
    providerType: 'zoho_voice_sms',
    displayName: 'Zoho Voice SMS',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://help.zoho.com/portal/en/kb/zoho-voice/zoho-voice-apis/articles/sms-rest-api',
    coverage: 'Countries enabled on the Zoho Voice account',
    notes: 'Zoho Voice (not Zoho Mail). Uses a self-client refresh token with scope ZohoVoice.sms.CREATE.',
    credentialFields: [
      secretField('client_id', 'OAuth client ID'),
      secretField('client_secret', 'OAuth client secret'),
      secretField('refresh_token', 'OAuth refresh token'),
    ],
    configurationFields: [
      configField('sender_id', 'Sender ID', true),
      configField('data_center', 'Data center', false, 'Zoho account domain; defaults to com', ZOHO_DATA_CENTERS),
    ],
    credentials: z.object({ client_id: text, client_secret: text, refresh_token: text }),
    configuration: z.object({ sender_id: text, data_center: z.enum(ZOHO_DATA_CENTERS).optional() }),
    create: (c, x) =>
      new ZohoVoiceSmsProvider(
        c as { client_id: string; client_secret: string; refresh_token: string },
        x as { sender_id: string },
      ),
  },
  {
    providerType: 'aws_sms',
    displayName: 'AWS End User Messaging SMS',
    channel: 'sms',
    status: 'available',
    otpModel: 'resqnet',
    docsUrl: 'https://docs.aws.amazon.com/pinpoint/latest/apireference_smsvoicev2/API_SendTextMessage.html',
    coverage: 'Countries enabled on the AWS account; India supports DLT entity/template IDs',
    notes: 'Use an IAM user limited to sms-voice:SendTextMessage. The account must be out of the SMS sandbox.',
    credentialFields: [secretField('access_key_id', 'Access key ID'), secretField('secret_access_key', 'Secret access key')],
    configurationFields: [
      configField('region', 'AWS region', true, 'For example ap-south-1'),
      configField('origination_identity', 'Origination identity', false, 'Phone number, sender ID, pool ID, or ARN'),
      configField('configuration_set', 'Configuration set', false),
      configField('in_entity_id', 'India DLT entity ID', false, 'Only sent for +91 destinations'),
      configField('in_template_id', 'India DLT template ID', false, 'Only sent for +91 destinations'),
    ],
    credentials: z.object({ access_key_id: z.string().trim().regex(/^[A-Z0-9]{16,128}$/), secret_access_key: text }),
    configuration: z.object({
      region: z.string().trim().regex(AWS_REGION_PATTERN, 'Invalid AWS region'),
      origination_identity: text.optional(),
      configuration_set: text.optional(),
      in_entity_id: text.optional(),
      in_template_id: text.optional(),
    }),
    create: (c, x) =>
      new AwsSmsProvider(c as { access_key_id: string; secret_access_key: string }, x as { region: string }),
  },
  {
    providerType: 'msg91',
    displayName: 'MSG91',
    channel: 'sms',
    status: 'coming_soon',
    otpModel: 'resqnet',
    docsUrl: 'https://docs.msg91.com/',
    coverage: 'India (DLT-registered templates)',
    notes:
      'MSG91 SendOTP stores and verifies codes on MSG91, which would move the OTP lifecycle out of ResQNet. ' +
      'The template Flow API can deliver a ResQNet-generated code, but its request contract has not yet been verified against official documentation.',
    credentialFields: [secretField('authkey', 'Auth key')],
    configurationFields: [configField('template_id', 'DLT template ID', true)],
    credentials: z.object({ authkey: text }),
    configuration: z.object({ template_id: text }),
  },
  {
    providerType: 'generic_http_sms',
    displayName: 'Generic HTTP SMS gateway',
    channel: 'sms',
    status: 'coming_soon',
    otpModel: 'resqnet',
    docsUrl: '',
    coverage: 'Depends on the gateway',
    notes:
      'Not enabled: an admin-supplied URL would let the backend be pointed at internal services (SSRF). ' +
      'Requires allowlisting, private-network and DNS-rebinding protection before it can be offered.',
    credentialFields: [],
    configurationFields: [],
    credentials: z.object({}),
    configuration: z.object({}),
  },
];

export type PublicProviderDefinition = Omit<ProviderDefinition, 'credentials' | 'configuration' | 'create'> & {
  available: boolean;
};

export function providerCatalog(): PublicProviderDefinition[] {
  return definitions.map(({ credentials: _c, configuration: _x, create: _create, ...definition }) => ({
    ...definition,
    available: definition.status === 'available',
  }));
}

export function getProviderDefinition(type: string): ProviderDefinition | undefined {
  return definitions.find((definition) => definition.providerType === type);
}

/** Validation failure naming the offending fields — never their values. */
export class ProviderSettingsError extends Error {
  constructor(
    message: string,
    public readonly fields: string[] = [],
  ) {
    super(message);
    this.name = 'ProviderSettingsError';
  }
}

function issuePaths(prefix: string, error: z.ZodError): string[] {
  return error.issues.map((issue) => [prefix, ...issue.path].join('.'));
}

/** Validates and normalizes (unknown keys stripped) a provider's settings. */
export function parseProviderSettings(type: string, credentials: Settings, configuration: Settings) {
  const definition = getProviderDefinition(type);
  if (!definition) throw new ProviderSettingsError('Unknown SMS provider type');
  const c = definition.credentials.safeParse(credentials);
  const x = definition.configuration.safeParse(configuration);
  if (!c.success || !x.success) {
    throw new ProviderSettingsError('Invalid SMS provider settings', [
      ...(c.success ? [] : issuePaths('credentials', c.error)),
      ...(x.success ? [] : issuePaths('configuration', x.error)),
    ]);
  }
  return { definition, credentials: c.data, configuration: x.data };
}

/** Builds a ready-to-send adapter. Any settings problem is reported as a
 * `configuration` failure so the fallback chain can move on. */
export function createProviderAdapter(type: string, credentials: Settings, configuration: Settings): SmsProvider {
  let settings: ReturnType<typeof parseProviderSettings>;
  try {
    settings = parseProviderSettings(type, credentials, configuration);
  } catch {
    throw new SmsProviderError('configuration', 'Stored SMS provider settings are invalid');
  }
  const { definition } = settings;
  if (definition.status !== 'available' || !definition.create) {
    throw new SmsProviderError('configuration', 'SMS provider is not available');
  }
  return definition.create(settings.credentials, settings.configuration);
}
