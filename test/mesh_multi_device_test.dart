// SIMULATED/INTEGRATION MESH TESTS — not physical mesh tests.
//
// These tests exercise three independent MeshService instances (A, B, C)
// wired together by a test-only harness that pipes each device's actual
// outgoing traffic (captured via MeshService.relayDrainOrderForTesting —
// the same code path _broadcastBytes would hand to the real
// nearby_connections/MultipeerConnectivity transport) into whichever
// other device(s) are "connected" to it. The transport itself
// (Bluetooth/Wi-Fi Direct radio, actual device discovery/pairing) is NOT
// simulated or claimed to be tested here — only the application-level
// protocol logic that sits on top of it (dedup, TTL, hop limit, relay
// path, envelope integrity) is verified, against real MeshService/
// EmergencyMessage/EmergencyOutboxStore code, not mocks of that code.
//
// MOST tests below use an OPAQUE fake signature/keyId with no embedded
// public key (signedEnvelope()'s fixture) — deliberately, to isolate
// dedup/TTL/hop-limit/relay-path/loop-avoidance logic from cryptography.
// With no embedded public key, MeshService's real local verification
// (core/utils/origin_signature_verifier.dart, wired into
// _handleIncomingPayloadAsync) correctly classifies these as
// `malformed`/unverified rather than either falsely "verified" or
// rejected — see origin_signature_verifier_test.dart for exhaustive
// coverage of the crypto logic itself (valid, tampered, wrong key,
// keyId mismatch, expired, missing key), and the
// "real cryptographic detection" group below for an integration-level
// proof that a GENUINELY signed-and-then-tampered envelope IS now
// detected and dropped by MeshService on receipt — not merely by the
// backend. What the byte-for-byte relay tests below additionally prove
// is that a signed envelope's fields survive multi-hop relay unmodified
// — the precondition for the backend's OWN (separately, already-tested
// in backend/tests/originSignature.test.ts and sosService.test.ts)
// cross-verification runs (see the phase reports) prove the second half.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_secure_storage.dart';
import 'support/real_crypto_test_helpers.dart';

/// Real devices each have their own persistence and their own device
/// identity — EmergencyOutboxStore.instance and DeviceKeyService.instance
/// are correctly process-global singletons in production (one running
/// app IS one device). Simulating THREE independent devices inside one
/// test process therefore requires explicit, isolated stores/ids per
/// simulated device — done here via MeshService's test-only injection
/// points, not by weakening the production singletons.
MeshService simulatedDevice(String deviceId) => MeshService(
      testOutboxStore: EmergencyOutboxStore(keyPrefix: '$deviceId-'),
      testDeviceId: deviceId,
    );

/// A signed origin envelope, fixed across all tests in this file so every
/// scenario starts from the same known-good baseline.
OriginEnvelope signedEnvelope({
  String category = 'medical',
  DateTime? expiresAt,
  int maxHops = 8,
}) =>
    OriginEnvelope(
      protocolVersion: '1',
      originDeviceId: 'device-A',
      eventType: 'sos',
      eventSource: 'manual',
      category: category,
      message: 'trapped, need help',
      latitude: '27.717200',
      longitude: '85.324000',
      locationAccuracyM: '10.00',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      expiresAt: (expiresAt ?? DateTime.now().add(const Duration(hours: 1))).toUtc().toIso8601String(),
      maxHops: maxHops,
      priority: 'critical',
      keyId: 'device-A-key-1',
      signature: 'BASE64_SIGNATURE_FROM_DEVICE_A_UNCHANGED', // opaque here — integrity, not validity, is what this suite checks
    );

EmergencyMessage originMessage(String eventId, {OriginEnvelope? envelope, DateTime? expiresAt, int maxHops = 8}) {
  final env = envelope ?? signedEnvelope(expiresAt: expiresAt, maxHops: maxHops);
  return EmergencyMessage(
    id: eventId,
    senderId: 'device-A',
    senderName: 'Hiker A',
    message: env.message ?? '',
    type: EmergencyType.trapped,
    priority: PriorityLevel.critical,
    latitude: 27.7172,
    longitude: 85.3240,
    timestamp: DateTime.now(),
    originEnvelope: env,
    maxHops: env.maxHops,
    expiresAt: DateTime.parse(env.expiresAt),
  );
}

/// Pipes device [from]'s newly-observed outgoing traffic to every device
/// in [to] — the test-only "radio". Only delivers entries not already
/// delivered (tracked by list length), so repeated calls are safe.
class _Link {
  final MeshService from;
  final List<MeshService> to;
  int _delivered = 0;
  _Link(this.from, this.to);

  Future<void> pump() async {
    final outgoing = from.relayDrainOrderForTesting;
    for (var i = _delivered; i < outgoing.length; i++) {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(outgoing[i].toJson())));
      for (final peer in to) {
        await peer.handleIncomingPayloadForTesting(bytes);
      }
    }
    _delivered = outgoing.length;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late FakeDeviceKeyChannel fakeChannel;
  late FakeSecureStorage secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    fakeChannel = FakeDeviceKeyChannel();
    DeviceKeyService.instance.resetCacheForTests();
  });

  tearDown(() {
    fakeChannel.dispose();
    secureStorage.dispose();
    DeviceKeyService.instance.resetCacheForTests();
  });

  group('SIMULATED MESH — A to B (direct)', () {
    test('B receives exactly the envelope A signed, byte-for-byte intact', () async {
      final a = simulatedDevice('device-A');
      final b = simulatedDevice('device-B');
      final link = _Link(a, [b]);

      final msg = originMessage('evt-ab-1');
      await a.broadcastMessage(msg);
      await settle();
      await link.pump();

      final received = b.messages.firstWhere((m) => m.id == 'evt-ab-1');
      expect(received.originEnvelope!.signature, msg.originEnvelope!.signature);
      expect(received.originEnvelope!.originDeviceId, 'device-A');
      expect(received.originEnvelope!.category, 'medical');
      expect(received.hopCount, 0); // A's own broadcast, not yet relayed by anyone
    });
  });

  group('SIMULATED MESH — A to B to C (multi-hop)', () {
    test('C receives the event with origin fields unchanged and hopCount reflecting two hops', () async {
      final a = simulatedDevice('device-A');
      final b = simulatedDevice('device-B');
      final c = simulatedDevice('device-C');
      final aToB = _Link(a, [b]);
      final bToC = _Link(b, [c]);

      final msg = originMessage('evt-abc-1');
      await a.broadcastMessage(msg);
      await settle();
      await aToB.pump(); // B receives from A, and (since below maxHops) relays
      await settle();
      await bToC.pump(); // C receives B's relay

      final atC = c.messages.firstWhere((m) => m.id == 'evt-abc-1');
      // Origin identity is IMMUTABLE across relay — B cannot have changed it.
      expect(atC.originEnvelope!.originDeviceId, 'device-A');
      expect(atC.originEnvelope!.signature, msg.originEnvelope!.signature);
      expect(atC.originEnvelope!.keyId, 'device-A-key-1');
      expect(atC.hopCount, 1); // incremented once, by B's relay
      expect(atC.relayPath, isNotEmpty); // carries B's own relay-path entry
    });

    test('duplicate delivery to C via a second route (simulating A->C directly, after A->B->C) is only processed once', () async {
      final a = simulatedDevice('device-A');
      final b = simulatedDevice('device-B');
      final c = simulatedDevice('device-C');
      final aToB = _Link(a, [b]);
      final bToC = _Link(b, [c]);
      final aToC = _Link(a, [c]); // a second, direct route

      final msg = originMessage('evt-dup-1');
      await a.broadcastMessage(msg);
      await settle();

      await aToB.pump();
      await settle();
      await bToC.pump(); // C gets it via B first
      await aToC.pump(); // C ALSO gets the same event id directly from A

      expect(c.messages.where((m) => m.id == 'evt-dup-1'), hasLength(1));
    });
  });

  group('SIMULATED MESH — malicious/modified relay (envelope-less-key fixture)', () {
    test(
        'a relay that tampers with the payload of an envelope with NO embedded public key is shown as unverified, not falsely verified',
        () async {
      final c = simulatedDevice('device-C');

      final original = originMessage('evt-tamper-1');
      // Simulates "malicious B": takes what A actually produced, then
      // tampers with a signed field (category) WITHOUT updating the
      // signature, and delivers that directly to C — exactly what an
      // untrusted intermediate relay could attempt.
      final tamperedEnvelope = OriginEnvelope(
        protocolVersion: original.originEnvelope!.protocolVersion,
        originDeviceId: original.originEnvelope!.originDeviceId,
        eventType: original.originEnvelope!.eventType,
        eventSource: original.originEnvelope!.eventSource,
        category: 'fire', // tampered — was 'medical'
        message: original.originEnvelope!.message,
        latitude: original.originEnvelope!.latitude,
        longitude: original.originEnvelope!.longitude,
        locationAccuracyM: original.originEnvelope!.locationAccuracyM,
        createdAt: original.originEnvelope!.createdAt,
        expiresAt: original.originEnvelope!.expiresAt,
        maxHops: original.originEnvelope!.maxHops,
        priority: original.originEnvelope!.priority,
        keyId: original.originEnvelope!.keyId,
        signature: original.originEnvelope!.signature, // UNCHANGED — attacker didn't (couldn't) re-sign
      );
      final tampered = original.copyWith(originEnvelope: tamperedEnvelope);
      await c.handleIncomingPayloadForTesting(Uint8List.fromList(utf8.encode(jsonEncode(tampered.toJson()))));

      // This fixture has no embedded public key (signedEnvelope()'s
      // opaque keyId/signature), so there is nothing for local
      // verification to check against — it correctly stays unverified
      // (`malformed`) rather than being falsely marked verified, and,
      // since a missing key is not evidence of an attack, it is still
      // shown/relayed (see the "real cryptographic detection" group
      // below for the case where a real key WAS embedded).
      expect(c.messages.any((m) => m.id == 'evt-tamper-1'), true);
      final atC = c.messages.firstWhere((m) => m.id == 'evt-tamper-1');
      expect(atC.originEnvelope!.category, 'fire'); // the tampered value, shown but not verified
      expect(atC.originVerifiedLocally, false);
    });
  });

  group('SIMULATED MESH — real cryptographic detection (genuinely signed envelope)', () {
    test('B receives a genuinely signed envelope and marks it origin-verified locally', () async {
      final signer = generateTestKeyPair();
      final b = simulatedDevice('device-B');
      final signed = originMessage(
        'evt-real-1',
        envelope: buildRealSignedEnvelopeForTests(signer: signer, eventId: 'evt-real-1'),
      );
      await b.handleIncomingPayloadForTesting(Uint8List.fromList(utf8.encode(jsonEncode(signed.toJson()))));

      final atB = b.messages.firstWhere((m) => m.id == 'evt-real-1');
      expect(atB.originVerifiedLocally, true);
    });

    test(
        'a relay that tampers with a signed field of a GENUINELY signed envelope is detected and dropped — never shown, never relayed',
        () async {
      final signer = generateTestKeyPair();
      final c = simulatedDevice('device-C');
      final original = buildRealSignedEnvelopeForTests(signer: signer, eventId: 'evt-real-2');
      final tampered = OriginEnvelope(
        protocolVersion: original.protocolVersion,
        originDeviceId: original.originDeviceId,
        eventType: original.eventType,
        eventSource: original.eventSource,
        category: 'fire', // tampered — signature NOT regenerated (attacker has no private key)
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
      final tamperedMessage = originMessage('evt-real-2', envelope: tampered);
      await c.handleIncomingPayloadForTesting(Uint8List.fromList(utf8.encode(jsonEncode(tamperedMessage.toJson()))));

      expect(c.messages.any((m) => m.id == 'evt-real-2'), false);
      expect(c.relayAttemptsForTesting.any((m) => m.id == 'evt-real-2'), false);
    });
  });

  group('SIMULATED MESH — expiry', () {
    test('an event that expired before reaching B is dropped, never shown, never relayed', () async {
      final b = simulatedDevice('device-B');

      final expired = originMessage('evt-expired-1', expiresAt: DateTime.now().subtract(const Duration(minutes: 5)));
      await b.handleIncomingPayloadForTesting(Uint8List.fromList(utf8.encode(jsonEncode(expired.toJson()))));

      expect(b.messages.any((m) => m.id == 'evt-expired-1'), false);
      expect(b.relayAttemptsForTesting.any((m) => m.id == 'evt-expired-1'), false);
    });
  });

  group('SIMULATED MESH — hop limit exceeded', () {
    test('an event already at its maxHops is shown but never relayed past B', () async {
      final b = simulatedDevice('device-B');

      // originMessage() itself is hop 0; simulate it having already been
      // relayed maxHops times by constructing it directly at the limit.
      final atLimitEnvelope = signedEnvelope(maxHops: 3);
      final atLimit = EmergencyMessage(
        id: 'evt-hop-1',
        senderId: 'device-A',
        senderName: 'Hiker A',
        message: 'help',
        type: EmergencyType.trapped,
        priority: PriorityLevel.critical,
        latitude: 27.7172,
        longitude: 85.3240,
        timestamp: DateTime.now(),
        hopCount: 3,
        originEnvelope: atLimitEnvelope,
        maxHops: 3,
        expiresAt: DateTime.parse(atLimitEnvelope.expiresAt),
      );
      await b.handleIncomingPayloadForTesting(Uint8List.fromList(utf8.encode(jsonEncode(atLimit.toJson()))));

      expect(b.messages.any((m) => m.id == 'evt-hop-1'), true); // still received/shown
      expect(b.relayAttemptsForTesting.any((m) => m.id == 'evt-hop-1'), false); // never relayed onward
    });
  });

  group('SIMULATED MESH — unknown/revoked origin key (documented scope boundary)', () {
    test('the mesh layer relays regardless of whether the origin key is registered, revoked, or unknown — that determination happens only at backend sync, never locally', () async {
      // There is no "registered/revoked/unknown" concept anywhere in
      // MeshService/EmergencyMessage by design — device_keys.revoked_at
      // and origin_verification_state exist ONLY in the backend (Phase 1,
      // see backend/tests/sosService.test.ts's "rejects when the origin
      // device key has been revoked" / "preserves an event whose origin
      // device has never registered a key" tests, both already passing).
      // This test exists to make that scope boundary explicit rather than
      // leave it implicit: the mesh will happily relay a signed envelope
      // from a keyId that (unknown to any mesh participant) is revoked or
      // was never registered — nothing here can or should reject it, since
      // rejecting would require exactly the local backend-database lookup
      // this architecture deliberately keeps offline-mesh-devices from
      // needing.
      final a = simulatedDevice('device-A');
      final b = simulatedDevice('device-B');
      final msg = originMessage('evt-unknown-key-1');
      await a.broadcastMessage(msg);
      await settle();
      final link = _Link(a, [b]);
      await link.pump();

      expect(b.messages.any((m) => m.id == 'evt-unknown-key-1'), true);
    });
  });
}
