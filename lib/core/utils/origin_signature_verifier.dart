import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

import '../models/origin_envelope.dart';
import 'origin_signable_fields.dart';

/// Outcome of a LOCAL (offline, no backend round-trip) check of a signed
/// origin envelope, using the pointycastle package's audited ECDSA
/// implementation for VERIFICATION ONLY — this file never signs anything;
/// signing stays exclusively on native Android Keystore / iOS Secure
/// Enclave (DeviceKeyService).
///
/// Read every value here against what it actually proves, not what it
/// sounds like it proves:
/// - [signatureValidSelfConsistent] proves the canonical payload has not
///   changed since it was signed, and that whoever produced this
///   envelope holds the private key matching the embedded public key.
///   It does NOT prove that key belongs to any real, registered ResQNet
///   account — a relay or attacker can embed their own freshly-generated
///   keypair and self-sign consistently. Only the backend's
///   `verifyOriginSignature` (Phase 1), checked against its own
///   registered `device_keys.public_key` row, can make that stronger
///   claim. UI code must map this to "ORIGIN VERIFIED", never "BACKEND
///   VERIFIED".
enum LocalOriginVerificationResult {
  /// The envelope has no signature/key material to check at all (e.g. no
  /// envelope, or built before this field existed) — stays UNVERIFIED.
  noEnvelope,

  /// `originPublicKeyPem` was missing, not valid P-256 SPKI, or the
  /// signature was not parseable DER — malformed, never treated as
  /// verified.
  malformed,

  /// The embedded public key's own SHA-256 fingerprint does not match
  /// the envelope's declared `keyId` — internally inconsistent, reject.
  /// (Catches a relay that substitutes a different key without also
  /// updating the declared keyId to match.)
  keyIdMismatch,

  /// The event's own `expiresAt` (signed field) has already passed.
  expired,

  /// The ECDSA signature does NOT verify against the embedded public key
  /// over the canonical signed payload — tampered payload, forged
  /// signature, or wrong key. Must be dropped, never displayed or
  /// relayed as if genuine.
  signatureInvalid,

  /// Signature verifies against the embedded key over the canonical
  /// payload — see class doc comment for exactly what this does and does
  /// not prove.
  signatureValidSelfConsistent,
}

/// Fixed 26-byte DER header for an uncompressed P-256 SPKI public key —
/// identical bytes to android/app/.../DeviceKeyPlugin.kt's own SPKI
/// encoding and ios/Runner/DeviceKeyPlugin.swift's
/// `spkiDer(fromRawEcPoint:)`, confirmed byte-for-byte against both.
final Uint8List _p256SpkiHeader = Uint8List.fromList(const [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]);

/// Parses a `-----BEGIN PUBLIC KEY-----` PEM (SPKI DER, P-256) into its
/// raw SPKI DER bytes. Returns null (never throws) for anything that
/// doesn't parse as base64 or doesn't carry the expected P-256 SPKI
/// header — a malformed/foreign key is treated as absent, not crashed on.
Uint8List? _spkiDerFromPem(String pem) {
  final body = pem
      .replaceAll('-----BEGIN PUBLIC KEY-----', '')
      .replaceAll('-----END PUBLIC KEY-----', '')
      .replaceAll(RegExp(r'\s'), '');
  if (body.isEmpty) return null;
  final Uint8List der;
  try {
    der = base64Decode(body);
  } catch (_) {
    return null;
  }
  if (der.length != _p256SpkiHeader.length + 65) return null;
  for (var i = 0; i < _p256SpkiHeader.length; i++) {
    if (der[i] != _p256SpkiHeader[i]) return null;
  }
  return der;
}

/// SHA-256 fingerprint of SPKI DER bytes, base64url without padding —
/// must match android/app/.../DeviceKeyPlugin.kt's `fingerprint()` and
/// ios/Runner/DeviceKeyPlugin.swift's `fingerprint(spkiDer:)` exactly, so
/// a keyId means the same thing regardless of which platform (or this
/// local Dart check) computed it.
String _fingerprintSpkiDer(Uint8List spkiDer) {
  final digest = SHA256Digest().process(spkiDer);
  final base64Str = base64Encode(digest);
  return base64Str.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

/// Parses a DER-encoded ECDSA signature (SEQUENCE of two INTEGERs r, s —
/// the standard output of Android Keystore / iOS Secure Enclave / Node's
/// crypto.sign, exactly as documented in
/// backend/src/utils/originSignature.ts) into an [ECSignature]. Returns
/// null (never throws) for anything that doesn't parse as exactly that
/// shape.
ECSignature? _parseDerSignature(Uint8List der) {
  try {
    final sequence = ASN1Sequence.fromBytes(der);
    final elements = sequence.elements;
    if (elements == null || elements.length != 2) return null;
    final r = elements[0];
    final s = elements[1];
    if (r is! ASN1Integer || s is! ASN1Integer) return null;
    final rInt = r.integer;
    final sInt = s.integer;
    if (rInt == null || sInt == null) return null;
    return ECSignature(rInt, sInt);
  } catch (_) {
    return null;
  }
}

final ECDomainParameters _p256Params = ECDomainParameters('secp256r1');

/// Runs the full LOCAL verification flow for one received mesh envelope,
/// per the required receive-path order: caller is expected to have
/// already checked schema validity, expiry, and hop limit before calling
/// this (this function additionally re-checks expiry defensively, since
/// it is cheap and this function must be safe to call standalone, e.g.
/// from a test).
///
/// Never throws — any malformed input maps to a non-verified result.
LocalOriginVerificationResult verifyOriginEnvelopeLocally({
  required OriginEnvelope? envelope,
  required String eventId,
  DateTime? now,
}) {
  if (envelope == null) return LocalOriginVerificationResult.noEnvelope;
  final publicKeyPem = envelope.originPublicKeyPem;
  if (publicKeyPem == null || publicKeyPem.isEmpty) {
    return LocalOriginVerificationResult.malformed;
  }

  final spkiDer = _spkiDerFromPem(publicKeyPem);
  if (spkiDer == null) return LocalOriginVerificationResult.malformed;

  final computedKeyId = _fingerprintSpkiDer(spkiDer);
  if (computedKeyId != envelope.keyId) {
    return LocalOriginVerificationResult.keyIdMismatch;
  }

  final expiresAt = DateTime.tryParse(envelope.expiresAt);
  if (expiresAt == null) return LocalOriginVerificationResult.malformed;
  if ((now ?? DateTime.now().toUtc()).isAfter(expiresAt)) {
    return LocalOriginVerificationResult.expired;
  }

  final Uint8List signatureDer;
  try {
    signatureDer = base64Decode(envelope.signature);
  } catch (_) {
    return LocalOriginVerificationResult.malformed;
  }
  final signature = _parseDerSignature(signatureDer);
  if (signature == null) return LocalOriginVerificationResult.malformed;

  // Raw X9.63 point is the SPKI DER minus the fixed 26-byte header.
  final rawPoint = spkiDer.sublist(_p256SpkiHeader.length);
  final ECPoint? point;
  try {
    point = _p256Params.curve.decodePoint(rawPoint);
  } catch (_) {
    return LocalOriginVerificationResult.malformed;
  }
  if (point == null) return LocalOriginVerificationResult.malformed;

  final publicKey = ECPublicKey(point, _p256Params);
  final canonicalBytes = utf8.encode(buildSignableString(envelope.toSignableFields(eventId)));

  final verifier = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(publicKey));

  bool verified;
  try {
    verified = verifier.verifySignature(Uint8List.fromList(canonicalBytes), signature);
  } catch (_) {
    verified = false;
  }

  return verified
      ? LocalOriginVerificationResult.signatureValidSelfConsistent
      : LocalOriginVerificationResult.signatureInvalid;
}
