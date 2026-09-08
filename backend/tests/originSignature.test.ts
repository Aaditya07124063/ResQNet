import { generateKeyPairSync, sign as cryptoSign } from 'crypto';
import {
  assertValidP256PublicKey,
  buildSignableBytes,
  verifyOriginSignature,
  type SignableOriginFields,
} from '../src/utils/originSignature';

function baseFields(overrides: Partial<SignableOriginFields> = {}): SignableOriginFields {
  return {
    protocolVersion: '1',
    eventId: '11111111-1111-1111-1111-111111111111',
    originDeviceId: '22222222-2222-2222-2222-222222222222',
    eventType: 'sos',
    eventSource: 'manual',
    category: 'medical',
    message: 'need help',
    latitude: '12.345600',
    longitude: '77.654300',
    locationAccuracyM: '15.50',
    createdAt: '2026-01-01T00:00:00.000Z',
    expiresAt: '2026-01-01T00:10:00.000Z',
    maxHops: '5',
    priority: 'critical',
    ...overrides,
  };
}

/** Signs exactly the way a real ECDSA-P256-SHA256 client (Android
 * Keystore's "SHA256withECDSA", iOS's .ecdsaSignatureMessageX962SHA256)
 * would — a single SHA-256-then-ECDSA-sign over the raw canonical bytes,
 * producing a DER-encoded signature — proving this test exercises the
 * real interop contract, not a Node-specific shortcut. */
function signWithTestKey(privateKeyPem: string, fields: SignableOriginFields): string {
  const signature = cryptoSign('sha256', buildSignableBytes(fields), { key: privateKeyPem, dsaEncoding: 'der' });
  return signature.toString('base64');
}

function generateP256KeyPair() {
  return generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
}

describe('buildSignableBytes', () => {
  it('is deterministic — the same fields always produce the same bytes', () => {
    const fields = baseFields();
    expect(buildSignableBytes(fields)).toEqual(buildSignableBytes(fields));
  });

  it('changes if ANY single field changes (no field is ignored)', () => {
    const base = buildSignableBytes(baseFields());
    const fieldNames: (keyof SignableOriginFields)[] = [
      'protocolVersion',
      'eventId',
      'originDeviceId',
      'eventType',
      'eventSource',
      'category',
      'message',
      'latitude',
      'longitude',
      'locationAccuracyM',
      'createdAt',
      'expiresAt',
      'maxHops',
      'priority',
    ];
    for (const field of fieldNames) {
      const changed = buildSignableBytes(baseFields({ [field]: `${baseFields()[field]}-tampered` } as never));
      expect(changed).not.toEqual(base);
    }
  });

  it('cannot be confused by field-boundary shifting (length-prefixed framing defeats delimiter injection)', () => {
    // Without length-prefixing, category="a" + message="b|c" could collide
    // with category="a|b" + message="c" under a naive delimiter join.
    const a = buildSignableBytes(baseFields({ category: 'a', message: 'b|c' }));
    const b = buildSignableBytes(baseFields({ category: 'a|b', message: 'c' }));
    expect(a).not.toEqual(b);
  });

  it('treats null-coordinate ("") and a literal empty message differently from omission — both are just the empty string field, verified consistently', () => {
    const withEmptyMessage = buildSignableBytes(baseFields({ message: '' }));
    const withNoCoordinates = buildSignableBytes(baseFields({ latitude: '', longitude: '', locationAccuracyM: '' }));
    expect(withEmptyMessage).not.toEqual(withNoCoordinates);
  });
});

describe('verifyOriginSignature', () => {
  it('accepts a signature genuinely produced by the matching private key', () => {
    const { publicKey, privateKey } = generateP256KeyPair();
    const fields = baseFields();
    const signature = signWithTestKey(privateKey, fields);
    expect(verifyOriginSignature(fields, signature, publicKey)).toBe(true);
  });

  it('rejects a signature if a single signed field is modified after signing (payload tampering)', () => {
    const { publicKey, privateKey } = generateP256KeyPair();
    const fields = baseFields();
    const signature = signWithTestKey(privateKey, fields);
    const tampered = baseFields({ category: 'fire' }); // attacker escalates/changes the category
    expect(verifyOriginSignature(tampered, signature, publicKey)).toBe(false);
  });

  it('rejects a signature if originDeviceId is swapped for a different device (origin substitution/spoofing)', () => {
    const { publicKey, privateKey } = generateP256KeyPair();
    const fields = baseFields();
    const signature = signWithTestKey(privateKey, fields);
    const spoofed = baseFields({ originDeviceId: '99999999-9999-9999-9999-999999999999' });
    expect(verifyOriginSignature(spoofed, signature, publicKey)).toBe(false);
  });

  it('rejects a signature verified against the WRONG public key (a different device cannot claim this signature)', () => {
    const keyA = generateP256KeyPair();
    const keyB = generateP256KeyPair();
    const fields = baseFields();
    const signature = signWithTestKey(keyA.privateKey, fields);
    expect(verifyOriginSignature(fields, signature, keyB.publicKey)).toBe(false);
  });

  it('rejects a signature replayed against a different eventId (replay protection)', () => {
    const { publicKey, privateKey } = generateP256KeyPair();
    const fields = baseFields();
    const signature = signWithTestKey(privateKey, fields);
    const replayed = baseFields({ eventId: '33333333-3333-3333-3333-333333333333' });
    expect(verifyOriginSignature(replayed, signature, publicKey)).toBe(false);
  });

  it('never throws on malformed base64 signature input — returns false', () => {
    const { publicKey } = generateP256KeyPair();
    expect(verifyOriginSignature(baseFields(), 'not-valid-base64!!!', publicKey)).toBe(false);
  });

  it('never throws on empty signature input — returns false', () => {
    const { publicKey } = generateP256KeyPair();
    expect(verifyOriginSignature(baseFields(), '', publicKey)).toBe(false);
  });

  it('never throws on malformed public key material — returns false', () => {
    const { privateKey } = generateP256KeyPair();
    const signature = signWithTestKey(privateKey, baseFields());
    expect(verifyOriginSignature(baseFields(), signature, 'not a real pem key')).toBe(false);
  });

  it('rejects a signature that is well-formed base64 but not a valid DER ECDSA signature', () => {
    const { publicKey } = generateP256KeyPair();
    const garbageButValidBase64 = Buffer.from('this is not a der signature at all, just bytes').toString('base64');
    expect(verifyOriginSignature(baseFields(), garbageButValidBase64, publicKey)).toBe(false);
  });
});

describe('assertValidP256PublicKey', () => {
  it('accepts a genuine P-256 SPKI PEM public key', () => {
    const { publicKey } = generateP256KeyPair();
    expect(() => assertValidP256PublicKey(publicKey)).not.toThrow();
  });

  it('rejects a wrong-curve EC public key (e.g. P-384)', () => {
    const { publicKey } = generateKeyPairSync('ec', {
      namedCurve: 'secp384r1',
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    expect(() => assertValidP256PublicKey(publicKey)).toThrow(/curve/i);
  });

  it('rejects a non-EC (RSA) public key', () => {
    const { publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    expect(() => assertValidP256PublicKey(publicKey)).toThrow(/EC key/i);
  });

  it('rejects garbage input', () => {
    expect(() => assertValidP256PublicKey('not a key at all')).toThrow(/invalid public key/i);
  });
});
