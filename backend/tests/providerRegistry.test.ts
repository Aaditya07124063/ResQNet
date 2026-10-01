import {
  ProviderSettingsError,
  createProviderAdapter,
  parseProviderSettings,
  providerCatalog,
} from '../src/services/sms/providerRegistry';
import { SmsProviderError } from '../src/services/sms/SmsProviderError';

describe('providerCatalog', () => {
  const catalog = providerCatalog();

  it('never exposes validation schemas or adapter factories', () => {
    for (const entry of catalog) {
      expect(entry).not.toHaveProperty('credentials');
      expect(entry).not.toHaveProperty('configuration');
      expect(entry).not.toHaveProperty('create');
    }
  });

  it('marks every credential field as secret and keeps ResQNet as the OTP owner', () => {
    for (const entry of catalog) {
      expect(entry.otpModel).toBe('resqnet');
      expect(entry.channel).toBe('sms');
      for (const field of entry.credentialFields) expect(field.secret).toBe(true);
      for (const field of entry.configurationFields) expect(field.secret).toBe(false);
    }
  });

  it('keeps MSG91 and the generic HTTP gateway unavailable', () => {
    const status = Object.fromEntries(catalog.map((entry) => [entry.providerType, entry.status]));
    expect(status.msg91).toBe('coming_soon');
    expect(status.generic_http_sms).toBe('coming_soon');
    expect(status.sparrow_sms).toBe('available');
    expect(status.aws_sms).toBe('available');
  });

  it('does not list email products as SMS providers', () => {
    expect(catalog.map((entry) => entry.displayName).join(' ')).not.toMatch(/mail/i);
  });
});

describe('parseProviderSettings', () => {
  it('strips unknown keys and trims values', () => {
    const result = parseProviderSettings('sparrow_sms', { token: ' t ', extra: 'x' }, { from: 'ResQNet' });
    expect(result.credentials).toEqual({ token: 't' });
  });

  it('names the invalid fields without echoing values', () => {
    try {
      parseProviderSettings('twilio', { account_sid: 'not-a-sid-secret-value', auth_token: 'x' }, {});
      fail('expected validation to fail');
    } catch (err) {
      expect(err).toBeInstanceOf(ProviderSettingsError);
      const { fields, message } = err as ProviderSettingsError;
      expect(fields).toEqual(expect.arrayContaining(['credentials.account_sid', 'configuration.from_number']));
      expect(JSON.stringify({ fields, message })).not.toContain('not-a-sid-secret-value');
    }
  });

  it.each([
    ['sinch', { service_plan_id: 'p', sender: 's', region: 'attacker.example' }],
    ['zoho_voice_sms', { sender_id: 's', data_center: 'example.com/x' }],
    ['aws_sms', { region: 'us-east-1.attacker.example' }],
  ])('rejects a %s host component outside the allowlist', (type, configuration) => {
    const credentials =
      type === 'sinch'
        ? { api_token: 't' }
        : type === 'zoho_voice_sms'
          ? { client_id: 'a', client_secret: 'b', refresh_token: 'c' }
          : { access_key_id: 'AKIAEXAMPLEKEY1234', secret_access_key: 's' };
    expect(() => parseProviderSettings(type, credentials, configuration)).toThrow(ProviderSettingsError);
  });
});

describe('createProviderAdapter', () => {
  it('refuses a coming-soon provider as a configuration failure', () => {
    expect(() => createProviderAdapter('msg91', { authkey: 'k' }, { template_id: 't' })).toThrow(SmsProviderError);
  });

  it('refuses an unknown provider type', () => {
    expect(() => createProviderAdapter('nope', {}, {})).toThrow(SmsProviderError);
  });
});
