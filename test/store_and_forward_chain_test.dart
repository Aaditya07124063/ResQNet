// SIMULATED store-and-forward chain — NOT a physical radio test.
//
// Five independent MeshService instances (A–E), each with its own
// persisted outbox, dedup ledger, and relay store, joined by a test "radio"
// that only delivers between devices that are currently connected. Links
// come and go over time exactly as in the core scenario: A and C are never
// in range of each other, etc. The real Bluetooth/Wi-Fi Direct transport
// needs physical devices (see docs/PHYSICAL_TEST_PLAN.md).
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/emergency_communication_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/mesh_relay_store.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';
import 'support/real_crypto_test_helpers.dart';

const eventId = '11111111-1111-4111-8111-111111111111';

class Radio {
  final devices = <String, MeshService>{};
  final links = <String>{};
  final deliveries = <String>[]; // "from>to:eventId"

  String _key(String a, String b) => ([a, b]..sort()).join('|');

  MeshService add(String id) {
    final device = MeshService(
      testOutboxStore: EmergencyOutboxStore(keyPrefix: '$id-'),
      testRelayStore: MeshRelayStore(keyPrefix: '$id-'),
      testDeviceId: id,
      testSendBytes: (peer, bytes) async {
        if (!links.contains(_key(id, peer))) throw Exception('not in range');
        final eventIdSent = (jsonDecode(utf8.decode(bytes)) as Map)['id'];
        deliveries.add('$id>$peer:$eventIdSent');
        await devices[peer]!.handleIncomingPayloadForTesting(Uint8List.fromList(bytes), fromPeer: id);
      },
    );
    devices[id] = device;
    return device;
  }

  Future<void> connect(String a, String b) async {
    links.add(_key(a, b));
    devices[a]!.handleConnectionResultForTesting(b, true);
    devices[b]!.handleConnectionResultForTesting(a, true);
    await settle();
  }

  Future<void> disconnect(String a, String b) async {
    links.remove(_key(a, b));
    devices[a]!.handleConnectionResultForTesting(b, false);
    devices[b]!.handleConnectionResultForTesting(a, false);
    await settle();
  }

  bool has(String device) => devices[device]!.messages.any((m) => m.id == eventId);
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

EmergencyMessage signedSos(TestKeyPair signer, {int maxHops = 8, DateTime? expiresAt}) {
  final envelope = buildRealSignedEnvelopeForTests(
    signer: signer,
    eventId: eventId,
    originDeviceId: 'A',
    maxHops: maxHops,
    expiresAt: expiresAt,
  );
  return EmergencyMessage(
    id: eventId,
    senderId: 'user-a',
    senderName: 'Hiker A',
    message: envelope.message ?? '',
    type: EmergencyType.trapped,
    priority: PriorityLevel.critical,
    latitude: 27.7172,
    longitude: 85.324,
    timestamp: DateTime.now(),
    originEnvelope: envelope,
    maxHops: maxHops,
    expiresAt: DateTime.parse(envelope.expiresAt),
  );
}

void main() {
  late FakeSecureStorage secureStorage;
  late Radio radio;
  late TestKeyPair signer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    radio = Radio();
    for (final id in ['A', 'B', 'C', 'D', 'E']) {
      radio.add(id);
    }
    signer = generateTestKeyPair();
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  /// A creates the SOS with nobody in range, then each link exists only
  /// after the previous one is gone.
  Future<void> walkChain({required EmergencyMessage sos}) async {
    await radio.devices['A']!.broadcastMessage(sos, retainForNewPeers: true);
    for (final (from, to) in [('A', 'B'), ('B', 'C'), ('C', 'D'), ('D', 'E')]) {
      await radio.connect(from, to);
      await radio.disconnect(from, to);
    }
  }

  test('A → B → C → D → E: each device stores the SOS and forwards it to the next one later', () async {
    await walkChain(sos: signedSos(signer));

    for (final device in ['B', 'C', 'D', 'E']) {
      expect(radio.has(device), isTrue, reason: '$device should have received the SOS');
    }
    // Hop count grows by one per relay; the signed origin is unchanged.
    final atE = radio.devices['E']!.messages.firstWhere((m) => m.id == eventId);
    expect(atE.hopCount, 3);
    expect(atE.relayPath, ['A', 'B', 'C', 'D']);
    expect(atE.originVerifiedLocally, isTrue);
    expect(atE.originEnvelope!.originDeviceId, 'A');
  });

  test('the relay copy survives a "restart": a fresh MeshService on B still forwards to C', () async {
    await radio.devices['A']!.broadcastMessage(signedSos(signer), retainForNewPeers: true);
    await radio.connect('A', 'B');
    await radio.disconnect('A', 'B');

    // B's app restarts: new in-memory service, same persisted stores.
    radio.add('B');
    await radio.connect('B', 'C');
    expect(radio.has('C'), isTrue);
  });

  test('no event is sent twice over the same link, and never back to its sender', () async {
    await walkChain(sos: signedSos(signer));
    // Re-connecting old links does not resend.
    await radio.connect('B', 'C');
    await radio.connect('A', 'B');

    final perLink = <String, int>{};
    for (final d in radio.deliveries) {
      perLink[d] = (perLink[d] ?? 0) + 1;
    }
    expect(perLink.values.every((n) => n == 1), isTrue, reason: '$perLink');
    expect(radio.deliveries.where((d) => d.startsWith('B>A')), isEmpty);
    expect(radio.deliveries.where((d) => d.startsWith('C>B')), isEmpty);
  });

  test('a device reached by two paths keeps and shows the SOS once', () async {
    await radio.devices['A']!.broadcastMessage(signedSos(signer), retainForNewPeers: true);
    await radio.connect('A', 'B');
    await radio.connect('A', 'C');
    await radio.connect('B', 'D');
    await radio.connect('C', 'D');

    expect(radio.devices['D']!.messages.where((m) => m.id == eventId), hasLength(1));
  });

  test('the hop limit stops propagation (maxHops 2 = two relays: B and C forward, D receives but does not)', () async {
    await walkChain(sos: signedSos(signer, maxHops: 2));
    expect(radio.has('D'), isTrue);
    expect(radio.has('E'), isFalse);
    expect(radio.deliveries.where((d) => d.startsWith('D>')), isEmpty);
  });

  test('an expired SOS is not carried onward', () async {
    final sos = signedSos(signer, expiresAt: DateTime.now().add(const Duration(milliseconds: 300)));
    await radio.devices['A']!.broadcastMessage(sos, retainForNewPeers: true);
    await radio.connect('A', 'B');
    await radio.disconnect('A', 'B');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await radio.connect('B', 'C');
    expect(radio.has('C'), isFalse);
  });

  group('gateway (E has Internet)', () {
    late List<http.Request> uploads;

    setUp(() async {
      uploads = [];
      await TokenStorage.instance.save(accessToken: 'e-access', refreshToken: 'e-refresh');
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((request) async {
        final r = request as http.Request;
        uploads.add(r);
        return jsonStreamedResponse(201, {
          'event': {'id': 'server-row', 'originVerificationState': 'verified'},
        });
      }));
    });

    test('E uploads A\'s signed SOS once, with the original envelope, and not again on the next sync', () async {
      await walkChain(sos: signedSos(signer));
      final gateway = EmergencyCommunicationService(relayStore: MeshRelayStore(keyPrefix: 'E-'));

      await gateway.syncPendingEvents();
      await gateway.syncPendingEvents();

      final sosUploads = uploads.where((r) => r.url.path == '/api/v1/sos').toList();
      expect(sosUploads, hasLength(1));
      final body = jsonDecode(sosUploads.single.body) as Map<String, dynamic>;
      expect(body['eventId'], eventId);
      expect((body['originEnvelope'] as Map)['originDeviceId'], 'A');
      expect(sosUploads.single.headers['Authorization'], 'Bearer e-access');
      expect(gateway.lastGatewayUploadCount, 0, reason: 'nothing new on the second sync');

      final record = (await MeshRelayStore(keyPrefix: 'E-').loadAll()).single;
      expect(record.gatewayState, GatewayUploadState.uploaded);
    });

    test('offline gateway: keeps the SOS pending and uploads it when the network returns', () async {
      await walkChain(sos: signedSos(signer));
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw Exception('offline')));
      final gateway = EmergencyCommunicationService(relayStore: MeshRelayStore(keyPrefix: 'E-'));
      await gateway.syncPendingEvents();
      expect((await MeshRelayStore(keyPrefix: 'E-').loadAll()).single.gatewayState, GatewayUploadState.pending);

      // Connectivity returns after the retry backoff.
      await MeshRelayStore(keyPrefix: 'E-').update(
        eventId,
        (r) => r.copyWith(lastGatewayAttemptAt: DateTime.now().subtract(const Duration(hours: 1))),
      );
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((r) async {
        uploads.add(r as http.Request);
        return jsonStreamedResponse(201, {'event': {'id': 'x'}});
      }));
      await gateway.syncPendingEvents();
      expect(uploads.where((r) => r.url.path == '/api/v1/sos'), hasLength(1));
    });

    test('a gateway without a ResQNet session keeps carrying the SOS (401 is not a failure)', () async {
      await walkChain(sos: signedSos(signer));
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((r) async =>
          jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'no session'}})));
      final gateway = EmergencyCommunicationService(relayStore: MeshRelayStore(keyPrefix: 'E-'));
      await gateway.syncPendingEvents();
      final record = (await MeshRelayStore(keyPrefix: 'E-').loadAll()).single;
      expect(record.gatewayState, GatewayUploadState.pending);
      expect(record.gatewayAttempts, 0);
    });

    test('a definitive rejection (invalid signature) is not retried', () async {
      await walkChain(sos: signedSos(signer));
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((r) async {
        uploads.add(r as http.Request);
        return jsonStreamedResponse(400, {'error': {'code': 'BAD_REQUEST', 'message': 'Invalid origin signature'}});
      }));
      final gateway = EmergencyCommunicationService(relayStore: MeshRelayStore(keyPrefix: 'E-'));
      await gateway.syncPendingEvents();
      await MeshRelayStore(keyPrefix: 'E-').update(
        eventId,
        (r) => r.copyWith(lastGatewayAttemptAt: DateTime.now().subtract(const Duration(hours: 1))),
      );
      await gateway.syncPendingEvents();
      expect(uploads.where((r) => r.url.path == '/api/v1/sos'), hasLength(1));
      expect((await MeshRelayStore(keyPrefix: 'E-').loadAll()).single.gatewayState, GatewayUploadState.rejected);
    });
  });

  group('what a gateway must never upload', () {
    test('unsigned events and cancellation notices are carried but not uploaded', () {
      final unsigned = EmergencyMessage(
        id: eventId,
        senderId: 'x',
        senderName: 'x',
        message: 'help',
        type: EmergencyType.general,
        priority: PriorityLevel.critical,
        timestamp: DateTime.now(),
      );
      expect(isGatewayUploadable(unsigned), isFalse);

      final cancel = signedSos(signer).copyWith(cancelsEventId: '22222222-2222-4222-8222-222222222222');
      expect(isGatewayUploadable(cancel), isFalse);
      expect(isGatewayUploadable(signedSos(signer)), isTrue);
    });
  });
}
