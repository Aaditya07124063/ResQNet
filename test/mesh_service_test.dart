import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_secure_storage.dart';

EmergencyMessage fakeMessage({
  String id = 'event-1',
  int hopCount = 0,
  int maxHops = 8,
  DateTime? expiresAt,
  List<String> relayPath = const [],
  PriorityLevel priority = PriorityLevel.critical,
}) =>
    EmergencyMessage(
      id: id,
      senderId: 'sender-1',
      senderName: 'Sender',
      message: 'help needed',
      type: EmergencyType.medical,
      priority: priority,
      latitude: 12.3456,
      longitude: 77.6543,
      timestamp: DateTime.now(),
      hopCount: hopCount,
      maxHops: maxHops,
      expiresAt: expiresAt ?? DateTime.now().add(const Duration(hours: 1)),
      relayPath: relayPath,
    );

Uint8List encode(EmergencyMessage message) => Uint8List.fromList(utf8.encode(jsonEncode(message.toJson())));

void main() {
  late FakeDeviceKeyChannel fakeChannel;
  late FakeSecureStorage secureStorage;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    fakeChannel = FakeDeviceKeyChannel(keyId: 'local-key');
    DeviceKeyService.instance.resetCacheForTests();
  });

  tearDown(() {
    fakeChannel.dispose();
    secureStorage.dispose();
    DeviceKeyService.instance.resetCacheForTests();
  });

  group('broadcastMessage', () {
    test('adds the message to local history exactly once, even if broadcast twice', () async {
      final mesh = MeshService();
      final msg = fakeMessage();

      await mesh.broadcastMessage(msg);
      await mesh.broadcastMessage(msg);

      expect(mesh.messages.where((m) => m.id == 'event-1'), hasLength(1));
    });

    test('offers the message to the relay queue for onward transmission', () async {
      final mesh = MeshService();
      await mesh.broadcastMessage(fakeMessage());
      expect(mesh.relayAttemptsForTesting, isNotEmpty);
    });
  });

  group('handleIncomingPayloadForTesting — deduplication', () {
    test('a fresh message is added to local history', () async {
      final mesh = MeshService();
      await mesh.handleIncomingPayloadForTesting(encode(fakeMessage(id: 'event-A')));
      expect(mesh.messages.any((m) => m.id == 'event-A'), true);
    });

    test('the same event id received twice is only processed once (in-memory session)', () async {
      final mesh = MeshService();
      final bytes = encode(fakeMessage(id: 'event-B'));
      await mesh.handleIncomingPayloadForTesting(bytes);
      await mesh.handleIncomingPayloadForTesting(bytes);
      expect(mesh.messages.where((m) => m.id == 'event-B'), hasLength(1));
    });

    test('deduplication is PERSISTENT — a fresh MeshService instance (simulating an app restart) still rejects an already-processed id', () async {
      final firstInstanceMesh = MeshService();
      await firstInstanceMesh.handleIncomingPayloadForTesting(encode(fakeMessage(id: 'event-restart')));

      final secondInstanceMesh = MeshService(); // fresh in-memory state, same persisted storage
      await secondInstanceMesh.handleIncomingPayloadForTesting(encode(fakeMessage(id: 'event-restart')));

      expect(secondInstanceMesh.messages.any((m) => m.id == 'event-restart'), false);
    });

    test('a duplicate is never offered to the relay queue', () async {
      final mesh = MeshService();
      final bytes = encode(fakeMessage(id: 'event-C'));
      await mesh.handleIncomingPayloadForTesting(bytes);
      final countAfterFirst = mesh.relayAttemptsForTesting.length;
      await mesh.handleIncomingPayloadForTesting(bytes);
      expect(mesh.relayAttemptsForTesting.length, countAfterFirst);
    });
  });

  group('handleIncomingPayloadForTesting — TTL / expiration', () {
    test('an expired message is dropped — never added to local history', () async {
      final mesh = MeshService();
      final expired = fakeMessage(id: 'expired-1', expiresAt: DateTime.now().subtract(const Duration(minutes: 1)));
      await mesh.handleIncomingPayloadForTesting(encode(expired));
      expect(mesh.messages.any((m) => m.id == 'expired-1'), false);
    });

    test('an expired message is never offered to the relay queue', () async {
      final mesh = MeshService();
      final expired = fakeMessage(id: 'expired-2', expiresAt: DateTime.now().subtract(const Duration(minutes: 1)));
      await mesh.handleIncomingPayloadForTesting(encode(expired));
      expect(mesh.relayAttemptsForTesting, isEmpty);
    });

    test('a non-expired message is received normally', () async {
      final mesh = MeshService();
      final fresh = fakeMessage(id: 'fresh-1', expiresAt: DateTime.now().add(const Duration(days: 1)));
      await mesh.handleIncomingPayloadForTesting(encode(fresh));
      expect(mesh.messages.any((m) => m.id == 'fresh-1'), true);
    });
  });

  group('handleIncomingPayloadForTesting — hop limit', () {
    test('a message at its hop limit is still received (shown to the user) ...', () async {
      final mesh = MeshService();
      final atLimit = fakeMessage(id: 'hop-limit-1', hopCount: 5, maxHops: 5);
      await mesh.handleIncomingPayloadForTesting(encode(atLimit));
      expect(mesh.messages.any((m) => m.id == 'hop-limit-1'), true);
    });

    test('... but is NOT relayed further once at its hop limit', () async {
      final mesh = MeshService();
      final atLimit = fakeMessage(id: 'hop-limit-2', hopCount: 5, maxHops: 5);
      await mesh.handleIncomingPayloadForTesting(encode(atLimit));
      expect(mesh.relayAttemptsForTesting.any((m) => m.id == 'hop-limit-2'), false);
    });

    test('a message below its hop limit IS relayed further, with hopCount incremented', () async {
      final mesh = MeshService();
      final belowLimit = fakeMessage(id: 'hop-ok-1', hopCount: 2, maxHops: 8);
      await mesh.handleIncomingPayloadForTesting(encode(belowLimit));
      final relayed = mesh.relayAttemptsForTesting.firstWhere((m) => m.id == 'hop-ok-1');
      expect(relayed.hopCount, 3);
    });

    test('the maxHops enforced is the MESSAGE\'S OWN value, not a hardcoded constant', () async {
      final mesh = MeshService();
      // A message whose own signed maxHops is very low (2) must be
      // rejected for relay at hop 2, well before any old hardcoded
      // "hopCount < 10" constant would have stopped it.
      final tightLimit = fakeMessage(id: 'tight-limit', hopCount: 2, maxHops: 2);
      await mesh.handleIncomingPayloadForTesting(encode(tightLimit));
      expect(mesh.relayAttemptsForTesting.any((m) => m.id == 'tight-limit'), false);
    });
  });

  group('handleIncomingPayloadForTesting — loop avoidance', () {
    test('assigns a fresh messageId on each relay hop, distinct from the original', () async {
      final mesh = MeshService();
      final original = fakeMessage(id: 'loop-1', hopCount: 0, maxHops: 8);
      await mesh.handleIncomingPayloadForTesting(encode(original));
      final relayed = mesh.relayAttemptsForTesting.firstWhere((m) => m.id == 'loop-1');
      expect(relayed.messageId, isNotNull);
      expect(relayed.messageId, isNot(equals(original.messageId)));
    });

    test('appends this device\'s own id to the relay path when relaying', () async {
      final mesh = MeshService();
      final original = fakeMessage(id: 'loop-2', hopCount: 0, maxHops: 8);
      expect(original.relayPath, isEmpty);
      await mesh.handleIncomingPayloadForTesting(encode(original));
      final relayed = mesh.relayAttemptsForTesting.firstWhere((m) => m.id == 'loop-2');
      expect(relayed.relayPath, isNotEmpty);
      expect(relayed.relayPath, hasLength(original.relayPath.length + 1));
    });

    test('drops a message whose relay path already contains this device\'s own id (already passed through here)', () async {
      final mesh = MeshService();
      // First hop: learn this device's own id by relaying a normal message.
      await mesh.handleIncomingPayloadForTesting(encode(fakeMessage(id: 'loop-3a', hopCount: 0, maxHops: 8)));
      final ownDeviceId = mesh.relayAttemptsForTesting.firstWhere((m) => m.id == 'loop-3a').relayPath.last;

      // Now simulate a message that already claims to have passed
      // through this exact device.
      final alreadyVisited = fakeMessage(id: 'loop-3b', hopCount: 1, maxHops: 8, relayPath: [ownDeviceId]);
      await mesh.handleIncomingPayloadForTesting(encode(alreadyVisited));

      expect(mesh.relayAttemptsForTesting.any((m) => m.id == 'loop-3b'), false);
    });
  });

  group('relay priority ordering', () {
    test('a critical-priority message queued after several low-priority ones is still sent first — emergency traffic is never starved', () async {
      final mesh = MeshService();
      // Queue several low-priority messages first, back-to-back, so they
      // are all sitting in the relay queue before the critical one is
      // even created — a naive FIFO queue would send all of these first.
      for (var i = 0; i < 5; i++) {
        await mesh.broadcastMessage(fakeMessage(id: 'low-$i', priority: PriorityLevel.low));
      }
      await mesh.broadcastMessage(fakeMessage(id: 'critical-1', priority: PriorityLevel.critical));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(mesh.relayDrainOrderForTesting, hasLength(6));
      // The critical message must have drained BEFORE at least the last
      // of the low-priority ones queued ahead of it — proving priority,
      // not insertion order, determined send order.
      final criticalDrainIndex = mesh.relayDrainOrderForTesting.indexWhere((m) => m.id == 'critical-1');
      expect(criticalDrainIndex, lessThan(5));
    });
  });

  group('mesh security — payload size and history bounding (item 5 of FINAL GAP CLOSURE)', () {
    test('an oversized payload is rejected before any decode/parse attempt, never shown, never relayed', () async {
      final mesh = MeshService();
      // Larger than any legitimate message (text + coords + a full
      // 20s voice note tops out well under this) — simulates a
      // malicious/misbehaving peer flooding an oversized blob.
      final oversized = Uint8List(600 * 1024);
      await mesh.handleIncomingPayloadForTesting(oversized);

      expect(mesh.messages, isEmpty);
      expect(mesh.relayAttemptsForTesting, isEmpty);
    });

    test('a legitimately-sized payload just under the cap is still processed normally', () async {
      final mesh = MeshService();
      // A real message with a large (but legitimate) text field, still
      // comfortably under the cap.
      final big = fakeMessage(id: 'big-1').copyWith(message: 'x' * 100000);
      await mesh.handleIncomingPayloadForTesting(encode(big));

      expect(mesh.messages.any((m) => m.id == 'big-1'), true);
    });

    test('the displayed message history is bounded — the oldest entries are evicted once the cap is exceeded', () async {
      final mesh = MeshService();
      // Exceed the 500-entry cap with distinct, otherwise-valid events.
      for (var i = 0; i < 520; i++) {
        await mesh.handleIncomingPayloadForTesting(encode(fakeMessage(id: 'evt-$i')));
      }

      expect(mesh.messages.length, 500);
      // Newest-first ordering: the most recently received event must
      // still be present...
      expect(mesh.messages.any((m) => m.id == 'evt-519'), true);
      // ...while the oldest ones were evicted to make room.
      expect(mesh.messages.any((m) => m.id == 'evt-0'), false);
    });
  });
}
