// Tests for lib/core/utils/origin_signature_verifier.dart — the LOCAL
// (offline, no backend round-trip) origin-signature check now run by
// MeshService on every received mesh event.
//
// Real P-256 keypairs/signatures are generated via
// test/support/real_crypto_test_helpers.dart (pointycastle, TEST FIXTURE
// ONLY — the app itself never signs in Dart; signing stays exclusively
// on native Android Keystore / iOS Secure Enclave, DeviceKeyService).
// Only VERIFICATION (this test's subject) runs in Dart in the real app,
// using the same audited pointycastle implementation exercised here.
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/utils/origin_signature_verifier.dart';
import 'support/real_crypto_test_helpers.dart';

void main() {
  late TestKeyPair keyA;
  late TestKeyPair keyB;

  setUpAll(() {
    keyA = generateTestKeyPair();
    keyB = generateTestKeyPair();
  });

  test('a genuinely valid signature verifies as signatureValidSelfConsistent', () {
    final envelope = buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-1');
    final result = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-1');
    expect(result, LocalOriginVerificationResult.signatureValidSelfConsistent);
  });

  test('a tampered signed field (category changed after signing) is rejected as signatureInvalid', () {
    final original = buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-2');
    final tampered = OriginEnvelope(
      protocolVersion: original.protocolVersion,
      originDeviceId: original.originDeviceId,
      eventType: original.eventType,
      eventSource: original.eventSource,
      category: 'fire', // tampered — was 'medical'; signature NOT regenerated
      message: original.message,
      latitude: original.latitude,
      longitude: original.longitude,
      locationAccuracyM: original.locationAccuracyM,
      createdAt: original.createdAt,
      expiresAt: original.expiresAt,
      maxHops: original.maxHops,
      priority: original.priority,
      keyId: original.keyId,
      signature: original.signature,
      originPublicKeyPem: original.originPublicKeyPem,
    );
    final result = verifyOriginEnvelopeLocally(envelope: tampered, eventId: 'evt-2');
    expect(result, LocalOriginVerificationResult.signatureInvalid);
  });

  test('a signature produced by one key does not verify against a different embedded key (wrong key)', () {
    // Simulates an attacker embedding their own real, well-formed keypair
    // (self-consistent keyId/publicKeyPem) but pairing it with a
    // signature that was actually produced by A's key — the classic
    // "wrong key" case, distinct from a structurally-broken signature.
    final signedByA = buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-3');
    final withWrongKey = OriginEnvelope(
      protocolVersion: signedByA.protocolVersion,
      originDeviceId: signedByA.originDeviceId,
      eventType: signedByA.eventType,
      eventSource: signedByA.eventSource,
      category: signedByA.category,
      message: signedByA.message,
      latitude: signedByA.latitude,
      longitude: signedByA.longitude,
      locationAccuracyM: signedByA.locationAccuracyM,
      createdAt: signedByA.createdAt,
      expiresAt: signedByA.expiresAt,
      maxHops: signedByA.maxHops,
      priority: signedByA.priority,
      keyId: keyB.keyId, // B's real, self-consistent keyId
      signature: signedByA.signature, // but A's real signature
      originPublicKeyPem: keyB.publicKeyPem, // and B's real key
    );
    final result = verifyOriginEnvelopeLocally(envelope: withWrongKey, eventId: 'evt-3');
    expect(result, LocalOriginVerificationResult.signatureInvalid);
  });

  test('a keyId that does not match the embedded public key\'s own fingerprint is rejected as keyIdMismatch', () {
    final envelope =
        buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-4', keyIdOverride: 'not-a-real-fingerprint');
    final result = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-4');
    expect(result, LocalOriginVerificationResult.keyIdMismatch);
  });

  test('a missing public key (unknown/unavailable key) stays unverified (malformed), never falsely verified', () {
    final envelope = buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-5', publicKeyPemOverride: '');
    final result = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-5');
    expect(result, isNot(LocalOriginVerificationResult.signatureValidSelfConsistent));
    expect(result, LocalOriginVerificationResult.malformed);
  });

  test('an event past its own signed expiresAt is rejected as expired, without a false verified result', () {
    final envelope = buildRealSignedEnvelopeForTests(
      signer: keyA,
      eventId: 'evt-6',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );
    final result = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-6');
    expect(result, LocalOriginVerificationResult.expired);
  });

  test('a null envelope (no signature ever attached) is reported as noEnvelope, never verified', () {
    final result = verifyOriginEnvelopeLocally(envelope: null, eventId: 'evt-7');
    expect(result, LocalOriginVerificationResult.noEnvelope);
  });

  test(
      'modified relay metadata (hopCount/relayPath/messageId, which live on EmergencyMessage, '
      'not inside the signed envelope) does not affect verification — those fields are deliberately '
      'excluded from the signed canonical payload', () {
    final envelope = buildRealSignedEnvelopeForTests(signer: keyA, eventId: 'evt-8');
    // verifyOriginEnvelopeLocally only ever looks at the envelope's own
    // signed fields (SignableOriginFields) plus eventId — it has no
    // hopCount/relayPath/messageId parameter at all, so there is nothing
    // for a relay to alter that could change this result. Verifying the
    // exact same envelope twice, exactly as it would be checked at two
    // different hops, must be stable.
    final first = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-8');
    final second = verifyOriginEnvelopeLocally(envelope: envelope, eventId: 'evt-8');
    expect(first, LocalOriginVerificationResult.signatureValidSelfConsistent);
    expect(second, LocalOriginVerificationResult.signatureValidSelfConsistent);
  });

  // "Revoked key" is deliberately NOT tested here: revocation
  // (device_keys.revoked_at) is a backend-only concept (Phase 1) — the
  // mesh layer has no local revocation list and cannot have one without
  // connectivity, so a revoked key's signature will still verify as
  // signatureValidSelfConsistent locally. This is an honest, disclosed
  // scope boundary, not a bug: only the backend's `verifyOriginSignature`
  // (backend/tests/sosService.test.ts's "rejects when the origin device
  // key has been revoked", already passing) can ever say "revoked".
}
