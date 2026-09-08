// Real P-256 ECDSA keypair generation and signing, using pointycastle
// DIRECTLY, for TEST FIXTURES ONLY. The app itself never signs in Dart —
// signing stays exclusively on native Android Keystore / iOS Secure
// Enclave (DeviceKeyService). This file exists so tests can construct
// genuinely-signed OriginEnvelopes (needed to exercise
// core/utils/origin_signature_verifier.dart's real verification logic)
// without a native platform channel, mirroring how the backend's own
// test suite (backend/tests/originSignature.test.ts) generates test
// keys/signatures with Node's crypto module.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/utils/origin_signable_fields.dart';

final Uint8List p256SpkiHeaderForTests = Uint8List.fromList(const [
  0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]);

class TestKeyPair {
  final ECPublicKey publicKey;
  final ECPrivateKey privateKey;
  final String publicKeyPem;
  final String keyId;

  TestKeyPair(this.publicKey, this.privateKey, this.publicKeyPem, this.keyId);
}

SecureRandom seededSecureRandomForTests() {
  final random = FortunaRandom();
  final seedSource = Random.secure();
  final seeds = List<int>.generate(32, (_) => seedSource.nextInt(255));
  random.seed(KeyParameter(Uint8List.fromList(seeds)));
  return random;
}

String fingerprintSpkiDerForTests(Uint8List spkiDer) {
  final digest = SHA256Digest().process(spkiDer);
  final b64 = base64Encode(digest);
  return b64.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

String _toPem(Uint8List der) {
  final b64 = base64Encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, min(i + 64, b64.length)));
  }
  return '-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----\n';
}

TestKeyPair generateTestKeyPair() {
  final params = ECDomainParameters('secp256r1');
  final keyGen = ECKeyGenerator();
  keyGen.init(ParametersWithRandom(ECKeyGeneratorParameters(params), seededSecureRandomForTests()));
  final pair = keyGen.generateKeyPair();
  final publicKey = pair.publicKey;
  final privateKey = pair.privateKey;
  final rawPoint = publicKey.Q!.getEncoded(false);
  final spkiDer = Uint8List.fromList([...p256SpkiHeaderForTests, ...rawPoint]);
  return TestKeyPair(publicKey, privateKey, _toPem(spkiDer), fingerprintSpkiDerForTests(spkiDer));
}

/// Signs [canonicalString] with [keyPair] and DER-encodes the result —
/// exactly the shape Android Keystore/iOS Secure Enclave/Node's
/// crypto.sign all natively produce (SEQUENCE of two INTEGERs).
String signCanonicalStringForTests(TestKeyPair keyPair, String canonicalString) {
  final signer = ECDSASigner(SHA256Digest())
    ..init(true, ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(keyPair.privateKey), seededSecureRandomForTests()));
  final signature = signer.generateSignature(Uint8List.fromList(utf8.encode(canonicalString))) as ECSignature;
  final der = ASN1Sequence(elements: [ASN1Integer(signature.r), ASN1Integer(signature.s)]).encode();
  return base64Encode(der);
}

/// Builds a fully, genuinely signed [OriginEnvelope] for [eventId] using
/// [signer]'s real private key — a drop-in, cryptographically real
/// replacement for a hand-written fixture.
OriginEnvelope buildRealSignedEnvelopeForTests({
  required TestKeyPair signer,
  required String eventId,
  String originDeviceId = 'device-A',
  String category = 'medical',
  String message = 'trapped, need help',
  String latitude = '27.717200',
  String longitude = '85.324000',
  String locationAccuracyM = '10.00',
  DateTime? expiresAt,
  int maxHops = 8,
  String? keyIdOverride,
  String? publicKeyPemOverride,
}) {
  final createdAt = DateTime.now().toUtc().toIso8601String();
  final expires = (expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 1))).toIso8601String();
  final fields = SignableOriginFields(
    protocolVersion: '1',
    eventId: eventId,
    originDeviceId: originDeviceId,
    eventType: 'sos',
    eventSource: 'manual',
    category: category,
    message: message,
    latitude: latitude,
    longitude: longitude,
    locationAccuracyM: locationAccuracyM,
    createdAt: createdAt,
    expiresAt: expires,
    maxHops: maxHops.toString(),
    priority: 'critical',
  );
  final signature = signCanonicalStringForTests(signer, buildSignableString(fields));
  return OriginEnvelope(
    protocolVersion: '1',
    originDeviceId: originDeviceId,
    eventType: 'sos',
    eventSource: 'manual',
    category: category,
    message: message,
    latitude: latitude,
    longitude: longitude,
    locationAccuracyM: locationAccuracyM,
    createdAt: createdAt,
    expiresAt: expires,
    maxHops: maxHops,
    priority: 'critical',
    keyId: keyIdOverride ?? signer.keyId,
    signature: signature,
    originPublicKeyPem: publicKeyPemOverride ?? signer.publicKeyPem,
  );
}
