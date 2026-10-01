import { createHash, createPrivateKey, createPublicKey, sign as cryptoSign, verify as cryptoVerify } from 'node:crypto';
import type { EmergencyAlert } from '../services/alertService';

// Server signatures for emergency alerts, so an alert keeps its source
// label (e.g. OFFICIAL) when phones relay it over the offline mesh: the app
// verifies each relayed alert against the server's pinned public key and
// treats anything that fails as an unverified community report.
//
// Canonical form: "resqnet-alert-v1" followed by every field as
// `<utf8 byte length>:<value>` — unambiguous (no delimiter can be forged
// inside a value) and byte-identical in the Dart verifier
// (lib/core/security/alert_signature.dart). `updatedAt` is signed, so an
// older signed version can be recognised and never replace a newer one.

export const ALERT_SIGNATURE_VERSION = 'resqnet-alert-v1';

function field(value: string): string {
  return `${Buffer.byteLength(value, 'utf8')}:${value}`;
}

const fixed = (n: number | null, digits: number) => (n === null ? '' : n.toFixed(digits));

export function canonicalAlertString(alert: EmergencyAlert): string {
  return (
    ALERT_SIGNATURE_VERSION +
    [
      alert.id,
      alert.sourceType,
      alert.sourceName,
      alert.category,
      alert.severity,
      alert.status,
      alert.title,
      alert.body,
      alert.instructions ?? '',
      fixed(alert.area.latitude, 6),
      fixed(alert.area.longitude, 6),
      fixed(alert.area.radiusKm, 3),
      alert.area.province ?? '',
      alert.area.district ?? '',
      alert.area.municipality ?? '',
      alert.issuedAt,
      alert.expiresAt ?? '',
      alert.updatedAt,
    ]
      .map(field)
      .join('')
  );
}

export interface AlertSigner {
  keyId: string;
  sign(alert: EmergencyAlert): string;
}

/** SHA-256 of the SPKI DER, base64url — same key-id scheme as device keys. */
export function keyIdForPublicKeyPem(publicKeyPem: string): string {
  const der = createPublicKey(publicKeyPem).export({ type: 'spki', format: 'der' });
  return createHash('sha256').update(der).digest('base64url');
}

/**
 * Builds a signer from a base64-encoded PKCS#8 PEM P-256 private key
 * (`OFFICIAL_ALERT_SIGNING_KEY`). Returns null when unset: alerts are then
 * served unsigned and are only shown as official on phones that fetched them
 * from the server directly.
 */
export function createAlertSigner(base64Pem: string | undefined): AlertSigner | null {
  if (!base64Pem) return null;
  const privateKey = createPrivateKey(Buffer.from(base64Pem, 'base64').toString('utf8'));
  if (privateKey.asymmetricKeyType !== 'ec') throw new Error('OFFICIAL_ALERT_SIGNING_KEY must be an EC (P-256) key');
  const publicKeyPem = createPublicKey(privateKey).export({ type: 'spki', format: 'pem' }).toString();
  const keyId = keyIdForPublicKeyPem(publicKeyPem);
  return {
    keyId,
    sign: (alert) =>
      cryptoSign('sha256', Buffer.from(canonicalAlertString(alert), 'utf8'), { key: privateKey, dsaEncoding: 'der' }).toString(
        'base64',
      ),
  };
}

export function verifyAlertSignature(alert: EmergencyAlert, signatureBase64: string, publicKeyPem: string): boolean {
  try {
    return cryptoVerify(
      'sha256',
      Buffer.from(canonicalAlertString(alert), 'utf8'),
      { key: publicKeyPem, dsaEncoding: 'der' },
      Buffer.from(signatureBase64, 'base64'),
    );
  } catch {
    return false;
  }
}
