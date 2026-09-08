import { createPublicKey, verify as cryptoVerify, type KeyObject } from 'crypto';
import { HttpError } from './httpError';

/**
 * Cryptographic origin authentication for mesh-relayed SOS events.
 *
 * Algorithm: ECDSA over NIST P-256 (secp256r1/prime256v1), SHA-256 digest.
 * Chosen (not invented) because it's the one asymmetric algorithm natively
 * supported, hardware-backed, by all four platforms this needs to work
 * on: Android Keystore (API 23+, StrongBox where available), iOS Secure
 * Enclave (which supports ONLY P-256 — this is the real reason Ed25519,
 * otherwise a fine modern choice, was not used), Node's built-in `crypto`
 * (no new backend dependency), and a Flutter/native platform-channel
 * bridge (mirroring the existing mesh_service_ios.dart pattern). All three
 * platforms' native signing APIs (Android's "SHA256withECDSA", iOS's
 * `.ecdsaSignatureMessageX962SHA256`, Node's `crypto.sign('sha256', ...)`
 * for EC keys) produce the same DER-encoded (ASN.1 SEQUENCE of two
 * INTEGERs) signature format by default — no format conversion needed
 * between platforms.
 *
 * Canonical signed representation: NOT raw JSON. JSON field order and
 * number-to-string formatting are not guaranteed identical between Dart
 * and Node, which is a well-known source of cross-language signature
 * bugs. Instead this is a fixed-order, length-prefixed (netstring-style)
 * concatenation of EXACT STRINGS as the origin device produced them —
 * latitude/longitude/locationAccuracyM travel and are signed as the
 * origin's own fixed-decimal strings, never a value reformatted from a
 * parsed number, so no side of the verification ever needs Dart's and
 * JS's floating-point-to-string output to agree byte-for-byte.
 *
 * `hopCount`/`relayDeviceId`/`relayPath` are deliberately NOT part of the
 * signed representation — they must change at every mesh hop by design.
 * This is a disclosed, real residual limitation: a dishonest relay can
 * still misreport hop count, so `maxHops` enforcement against a
 * relay-reported hopCount is not itself tamper-proof. What signing DOES
 * guarantee: the emergency payload, its origin device identity, and its
 * expiry cannot be modified, substituted, or replayed by any relay.
 */

export interface SignableOriginFields {
  protocolVersion: string;
  eventId: string;
  originDeviceId: string;
  eventType: string;
  eventSource: string;
  category: string;
  /** '' when there is no message — never `null`/`undefined` here; the
   * caller normalizes before this point. */
  message: string;
  /** Exact origin-produced decimal string, or '' for "no coordinates". */
  latitude: string;
  longitude: string;
  locationAccuracyM: string;
  /** ISO-8601 string, exactly as the origin produced it (validated for
   * shape by zod, never reformatted). */
  createdAt: string;
  expiresAt: string;
  maxHops: string;
  priority: string;
}

const SIGNING_DOMAIN = 'resqnet-sos-sig-v1';

const FIELD_ORDER: (keyof SignableOriginFields)[] = [
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

function frame(value: string): string {
  // Length-prefixed (netstring-style) framing — makes every field
  // boundary unambiguous regardless of what characters (including
  // newlines or digits) appear inside a free-text field like `message`,
  // so no delimiter-injection ambiguity is possible.
  return `${Buffer.byteLength(value, 'utf8')}:${value}`;
}

/** Builds the exact byte sequence that gets signed/verified. Public so a
 * future reconciliation path and tests can both call the identical
 * function used at creation time — there must only ever be one place this
 * is computed. */
export function buildSignableBytes(fields: SignableOriginFields): Buffer {
  const framed = [SIGNING_DOMAIN, ...FIELD_ORDER.map((key) => fields[key])].map(frame).join('');
  return Buffer.from(framed, 'utf8');
}

/**
 * Verifies a signature was produced by the private key matching
 * `publicKeyPem` over exactly `fields`. Never throws — a malformed key,
 * malformed base64, or a genuine mismatch are all indistinguishable
 * "no" answers to the caller (a caller must not learn WHY verification
 * failed, only that it did).
 */
export function verifyOriginSignature(fields: SignableOriginFields, signatureBase64: string, publicKeyPem: string): boolean {
  try {
    const publicKey = createPublicKey(publicKeyPem);
    const signature = Buffer.from(signatureBase64, 'base64');
    if (signature.length === 0) return false;
    return cryptoVerify('sha256', buildSignableBytes(fields), { key: publicKey, dsaEncoding: 'der' }, signature);
  } catch {
    return false;
  }
}

/** True IFF `pem` parses as a valid ECDSA P-256 (prime256v1/secp256r1)
 * public key. Validated at REGISTRATION time (not just at verify time) so
 * a malformed or wrong-algorithm key is rejected with a clear 400 before
 * it can ever be stored and silently fail every future verification. */
export function assertValidP256PublicKey(pem: string): void {
  let keyObject: KeyObject;
  try {
    keyObject = createPublicKey(pem);
  } catch {
    throw HttpError.badRequest('Invalid public key material');
  }
  if (keyObject.asymmetricKeyType !== 'ec') {
    throw HttpError.badRequest('Public key must be an EC key');
  }
  const details = keyObject.asymmetricKeyDetails as { namedCurve?: string } | undefined;
  if (details?.namedCurve !== 'prime256v1') {
    throw HttpError.badRequest('Public key must use the P-256 (prime256v1/secp256r1) curve');
  }
}
