import { env } from '../src/config/env';
import { encryptCredentials, decryptCredentials } from '../src/utils/credentialEncryption';

describe('credentialEncryption', () => {
  const originalKey = env.PROVIDER_CREDENTIALS_ENCRYPTION_KEY;

  afterEach(() => {
    env.PROVIDER_CREDENTIALS_ENCRYPTION_KEY = originalKey;
  });

  it('round-trips a credentials object', () => {
    const secret = { token: 'sparrow-api-token-abc123' };
    const blob = encryptCredentials(secret);
    expect(decryptCredentials(blob)).toEqual(secret);
  });

  it('produces a different ciphertext each time for the same input (random IV)', () => {
    const secret = { token: 'same-token' };
    const blob1 = encryptCredentials(secret);
    const blob2 = encryptCredentials(secret);
    expect(blob1.equals(blob2)).toBe(false);
  });

  it('never embeds the plaintext credential value in the encrypted blob', () => {
    const secret = { token: 'super-secret-value-should-not-appear' };
    const blob = encryptCredentials(secret);
    expect(blob.toString('utf8')).not.toContain('super-secret-value-should-not-appear');
    expect(blob.toString('base64')).not.toContain('super-secret-value-should-not-appear');
  });

  it('throws when the encryption key is missing (fails safely, never falls back to plaintext)', () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (env as any).PROVIDER_CREDENTIALS_ENCRYPTION_KEY = undefined;
    expect(() => encryptCredentials({ token: 'x' })).toThrow(/PROVIDER_CREDENTIALS_ENCRYPTION_KEY/);
  });

  it('throws when decrypting without a configured key', () => {
    const blob = encryptCredentials({ token: 'x' });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (env as any).PROVIDER_CREDENTIALS_ENCRYPTION_KEY = undefined;
    expect(() => decryptCredentials(blob)).toThrow(/PROVIDER_CREDENTIALS_ENCRYPTION_KEY/);
  });

  it('rejects a key that does not decode to exactly 32 bytes', () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (env as any).PROVIDER_CREDENTIALS_ENCRYPTION_KEY = Buffer.alloc(16, 1).toString('base64');
    expect(() => encryptCredentials({ token: 'x' })).toThrow(/32 bytes/);
  });

  it('fails closed (throws, never returns garbage plaintext) on a tampered ciphertext', () => {
    const blob = encryptCredentials({ token: 'x' });
    const tampered = Buffer.from(blob);
    const lastByteIndex = tampered.length - 1;
    tampered.writeUInt8(tampered.readUInt8(lastByteIndex) ^ 0xff, lastByteIndex); // flip the last ciphertext byte
    expect(() => decryptCredentials(tampered)).toThrow();
  });

  it('fails closed on a tampered auth tag', () => {
    const blob = encryptCredentials({ token: 'x' });
    const tampered = Buffer.from(blob);
    tampered.writeUInt8(tampered.readUInt8(15) ^ 0xff, 15); // byte inside the 16-byte auth tag (offset 12..27)
    expect(() => decryptCredentials(tampered)).toThrow();
  });

  it('fails closed when decrypted with the wrong key', () => {
    const blob = encryptCredentials({ token: 'x' });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (env as any).PROVIDER_CREDENTIALS_ENCRYPTION_KEY = Buffer.alloc(32, 9).toString('base64');
    expect(() => decryptCredentials(blob)).toThrow();
  });

  it('rejects a blob too short to contain an IV and auth tag', () => {
    expect(() => decryptCredentials(Buffer.alloc(4))).toThrow(/too short/);
  });
});
