import fixture from './fixtures/signed_alert.json';
import { generateKeyPairSync } from 'node:crypto';
import { canonicalAlertString, createAlertSigner, keyIdForPublicKeyPem, verifyAlertSignature } from '../src/utils/alertSignature';
import type { EmergencyAlert } from '../src/services/alertService';

const { signature, signingKeyId, ...alert } = fixture.alert as EmergencyAlert & { signature: string; signingKeyId: string };

describe('alert signatures', () => {
  it('verifies the shared fixture (the Flutter verifier checks the same file)', () => {
    expect(verifyAlertSignature(alert, signature, fixture.publicKeyPem)).toBe(true);
    expect(keyIdForPublicKeyPem(fixture.publicKeyPem)).toBe(signingKeyId);
  });

  it.each([
    ['title', { title: 'All clear' }],
    ['source type', { sourceType: 'community' }],
    ['status', { status: 'resolved' }],
    ['expiry', { expiresAt: '2030-01-01T00:00:00.000Z' }],
    ['version (updatedAt)', { updatedAt: '2026-09-27T09:00:00.000Z' }],
    ['area', { area: { ...alert.area, radiusKm: 50 } }],
  ])('rejects an altered %s', (_name, change) => {
    expect(verifyAlertSignature({ ...alert, ...change } as EmergencyAlert, signature, fixture.publicKeyPem)).toBe(false);
  });

  it('a signature from a different key is rejected', () => {
    const other = generateKeyPairSync('ec', {
      namedCurve: 'prime256v1',
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' },
    });
    const forged = createAlertSigner(Buffer.from(other.privateKey).toString('base64'))!.sign(alert);
    expect(verifyAlertSignature(alert, forged, fixture.publicKeyPem)).toBe(false);
  });

  it('the canonical form cannot be shifted by moving text between fields', () => {
    const a = canonicalAlertString({ ...alert, title: 'AB', body: 'C' });
    const b = canonicalAlertString({ ...alert, title: 'A', body: 'BC' });
    expect(a).not.toBe(b);
  });

  it('no signer without a configured key', () => {
    expect(createAlertSigner(undefined)).toBeNull();
    expect(createAlertSigner('')).toBeNull();
  });
});
