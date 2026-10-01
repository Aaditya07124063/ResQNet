// SERVICE-LEVEL MESH TESTS — not physical Bluetooth/Wi-Fi Direct tests.
// Peer "connections" and "sends" are injected through MeshService's
// test hooks; the real transport needs two physical devices.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'support/real_crypto_test_helpers.dart';

EmergencyMessage sos(String id, {OriginEnvelope? envelope, PriorityLevel priority = PriorityLevel.critical}) =>
    EmergencyMessage(
      id: id,
      senderId: 'user-a',
      senderName: 'Hiker A',
      message: envelope?.message ?? 'trapped, need help',
      type: EmergencyType.trapped,
      priority: priority,
      latitude: 27.7172,
      longitude: 85.324,
      timestamp: DateTime.now(),
      originEnvelope: envelope,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
    );

EmergencyMessage cancellation(String id, String cancels, {OriginEnvelope? envelope}) => EmergencyMessage(
      id: id,
      senderId: 'user-a',
      senderName: 'Hiker A',
      message: 'Hiker A is safe — SOS cancelled.',
      type: EmergencyType.general,
      priority: PriorityLevel.high,
      timestamp: DateTime.now(),
      originEnvelope: envelope,
      expiresAt: envelope != null ? DateTime.parse(envelope.expiresAt) : null,
      cancelsEventId: cancels,
    );

Uint8List bytesOf(EmergencyMessage m) => Uint8List.fromList(utf8.encode(jsonEncode(m.toJson())));

const eventA = '11111111-1111-4111-8111-111111111111';
const cancelA = '22222222-2222-4222-8222-222222222222';

void main() {
  late EmergencyOutboxStore store;
  late List<(String, Map<String, dynamic>)> sent;
  late bool failSends;

  MeshService device() => MeshService(
        testOutboxStore: store,
        testDeviceId: 'device-self',
        testSendBytes: (peer, bytes) async {
          if (failSends) throw Exception('radio error');
          sent.add((peer, jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>));
        },
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = EmergencyOutboxStore(keyPrefix: 'test-');
    sent = [];
    failSends = false;
  });

  group('store-and-forward of this device\'s own SOS', () {
    test('an SOS raised with no peer in range reaches nobody — and is not counted as sent', () async {
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      expect(mesh.peersReachedFor(eventA), 0);
    });

    test('a peer that connects later receives the retained SOS, and the handoff is recorded', () async {
      await store.upsert(
          EmergencyOutboxEntry(eventId: eventA, eventSource: 'manual', category: 'trapped', createdAt: DateTime.now()));
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);

      mesh.handleConnectionResultForTesting('peer-1', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sent.map((s) => s.$1), ['peer-1']);
      expect(sent.single.$2['id'], eventA);
      expect(mesh.peersReachedFor(eventA), 1);
      expect((await store.get(eventA))!.sentToPeerIds, ['peer-1']);
    });

    test('each peer receives the SOS once, even across reconnects', () async {
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      mesh.handleConnectionResultForTesting('peer-1', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      mesh.handleConnectionResultForTesting('peer-1', false);
      mesh.handleConnectionResultForTesting('peer-1', true);
      mesh.handleConnectionResultForTesting('peer-2', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sent.map((s) => s.$1).toList(), ['peer-1', 'peer-2']);
      expect(mesh.peersReachedFor(eventA), 2);
    });

    test('a failed platform send is not counted as reaching the peer', () async {
      failSends = true;
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      mesh.handleConnectionResultForTesting('peer-1', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(mesh.peersReachedFor(eventA), 0);
    });

    test('a released (cancelled) SOS is no longer sent to new peers', () async {
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      mesh.releaseRetained(eventA);
      mesh.handleConnectionResultForTesting('peer-1', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sent, isEmpty);
    });

    test('broadcasting the same SOS twice does not send it twice (duplicate protection)', () async {
      final mesh = device();
      mesh.handleConnectionResultForTesting('peer-1', true);
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sent.where((s) => s.$2['id'] == eventA), hasLength(1));
    });

    test('an own cancellation stops re-sending the SOS and is itself delivered to new peers', () async {
      final mesh = device();
      await mesh.broadcastMessage(sos(eventA), retainForNewPeers: true);
      await mesh.broadcastMessage(cancellation(cancelA, eventA), retainForNewPeers: true);
      mesh.handleConnectionResultForTesting('peer-1', true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(sent.map((s) => s.$2['id']).toList(), [cancelA]);
      expect(sent.single.$2['cancelsEventId'], eventA);
      expect(mesh.cancellationFor(eventA)!.verified, isTrue);
    });
  });

  group('receiving emergencies', () {
    test('a new emergency is published once for notifications; a duplicate is not', () async {
      final mesh = device();
      final received = <String>[];
      mesh.incomingMessages.listen((m) => received.add(m.id));

      await mesh.handleIncomingPayloadForTesting(bytesOf(sos(eventA)));
      await mesh.handleIncomingPayloadForTesting(bytesOf(sos(eventA)));
      await Future<void>.delayed(Duration.zero);

      expect(received, [eventA]);
    });

    test('two copies of one SOS arriving at the same moment are shown and relayed once', () async {
      final mesh = device();
      final received = <String>[];
      mesh.incomingMessages.listen((m) => received.add(m.id));

      await Future.wait([
        mesh.handleIncomingPayloadForTesting(bytesOf(sos(eventA))),
        mesh.handleIncomingPayloadForTesting(bytesOf(sos(eventA).copyWith(hopCount: 1))),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(received, [eventA]);
      expect(mesh.messages.where((m) => m.id == eventA), hasLength(1));
      expect(mesh.relayAttemptsForTesting.where((m) => m.id == eventA), hasLength(1));
    });

    test('an expired emergency is neither shown nor published', () async {
      final mesh = device();
      final received = <String>[];
      mesh.incomingMessages.listen((m) => received.add(m.id));
      final expired = sos(eventA).copyWith(expiresAt: DateTime.now().subtract(const Duration(minutes: 1)));
      await mesh.handleIncomingPayloadForTesting(bytesOf(expired));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      expect(mesh.messages, isEmpty);
    });

    test('a received SOS at its hop limit is shown but not relayed further', () async {
      final mesh = device();
      final atLimit = sos(eventA).copyWith(hopCount: 8, maxHops: 8);
      await mesh.handleIncomingPayloadForTesting(bytesOf(atLimit));
      expect(mesh.messages.map((m) => m.id), [eventA]);
      expect(mesh.relayAttemptsForTesting, isEmpty);
    });
  });

  group('cancellation verification (real ECDSA signatures)', () {
    test('a cancellation signed by the same key as the SOS is verified', () async {
      final signer = generateTestKeyPair();
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(
          bytesOf(sos(eventA, envelope: buildRealSignedEnvelopeForTests(signer: signer, eventId: eventA))));
      await mesh.handleIncomingPayloadForTesting(bytesOf(cancellation(
        cancelA,
        eventA,
        envelope:
            buildRealSignedEnvelopeForTests(signer: signer, eventId: cancelA, message: cancellationSignedText(eventA)),
      )));

      expect(mesh.cancellationFor(eventA)!.verified, isTrue);
    });

    test('a cancellation signed by a different key cannot silence the SOS', () async {
      final owner = generateTestKeyPair();
      final attacker = generateTestKeyPair();
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(
          bytesOf(sos(eventA, envelope: buildRealSignedEnvelopeForTests(signer: owner, eventId: eventA))));
      await mesh.handleIncomingPayloadForTesting(bytesOf(cancellation(
        cancelA,
        eventA,
        envelope: buildRealSignedEnvelopeForTests(
            signer: attacker, eventId: cancelA, message: cancellationSignedText(eventA)),
      )));

      final result = mesh.cancellationFor(eventA);
      expect(result, isNotNull);
      expect(result!.verified, isFalse);
      expect(mesh.messages.any((m) => m.id == eventA), isTrue, reason: 'the SOS stays visible');
    });

    test('an unsigned cancellation is never verified', () async {
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(sos(eventA)));
      await mesh.handleIncomingPayloadForTesting(bytesOf(cancellation(cancelA, eventA)));
      expect(mesh.cancellationFor(eventA)!.verified, isFalse);
    });

    test('a same-key notice whose signed text names a different event is not accepted for this SOS', () async {
      final signer = generateTestKeyPair();
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(
          bytesOf(sos(eventA, envelope: buildRealSignedEnvelopeForTests(signer: signer, eventId: eventA))));
      await mesh.handleIncomingPayloadForTesting(bytesOf(cancellation(
        cancelA,
        eventA,
        envelope: buildRealSignedEnvelopeForTests(
            signer: signer, eventId: cancelA, message: cancellationSignedText('some-other-event')),
      )));
      expect(mesh.cancellationFor(eventA)!.verified, isFalse);
    });

    test('a cancellation that arrives before its SOS is verified once the SOS arrives', () async {
      final signer = generateTestKeyPair();
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(cancellation(
        cancelA,
        eventA,
        envelope:
            buildRealSignedEnvelopeForTests(signer: signer, eventId: cancelA, message: cancellationSignedText(eventA)),
      )));
      expect(mesh.cancellationFor(eventA)!.verified, isFalse);

      await mesh.handleIncomingPayloadForTesting(
          bytesOf(sos(eventA, envelope: buildRealSignedEnvelopeForTests(signer: signer, eventId: eventA))));
      expect(mesh.cancellationFor(eventA)!.verified, isTrue);
    });
  });
}
