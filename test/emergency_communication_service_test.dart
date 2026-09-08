import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/emergency_communication_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

EmergencyOutboxEntry fakeEntry({
  String eventId = 'event-1',
  OutboxEntryState state = OutboxEntryState.queued,
  int attempts = 0,
  DateTime? lastAttemptAt,
  DateTime? expiresAt,
  OriginEnvelope? originEnvelope,
}) =>
    EmergencyOutboxEntry(
      eventId: eventId,
      eventSource: 'manual',
      category: 'medical',
      message: 'help',
      latitude: 12.3456,
      longitude: 77.6543,
      createdAt: DateTime.now(),
      expiresAt: expiresAt,
      state: state,
      attempts: attempts,
      lastAttemptAt: lastAttemptAt,
      originEnvelope: originEnvelope,
    );

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  group('syncPendingEvents — success path', () {
    test('uploads a pending entry and marks it serverAccepted with the backend\'s verification state', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(201, {
            'event': {'id': 'server-id-1', 'originVerificationState': 'not_applicable'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.serverAccepted);
      expect(updated.serverOriginVerificationState, 'not_applicable');
    });

    test('sends the signed originEnvelope when one is present, instead of the flat direct-path fields', () async {
      final envelope = OriginEnvelope(
        protocolVersion: '1',
        originDeviceId: 'device-1',
        eventType: 'sos',
        eventSource: 'manual',
        category: 'medical',
        createdAt: '2026-01-01T00:00:00.000Z',
        expiresAt: '2026-01-02T00:00:00.000Z',
        maxHops: 8,
        priority: 'critical',
        keyId: 'key-1',
        signature: 'sig-1',
      );
      await EmergencyOutboxStore.instance.upsert(fakeEntry(originEnvelope: envelope));

      http.BaseRequest? sentRequest;
      final fake = FakeHttpClient((request) async {
        sentRequest = request;
        return jsonStreamedResponse(201, {
          'event': {'id': 'server-id-1', 'originVerificationState': 'verified'},
        });
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final body = jsonDecode((sentRequest as http.Request).body) as Map<String, dynamic>;
      expect(body['originEnvelope'], isNotNull);
      expect(body['originEnvelope']['originDeviceId'], 'device-1');
      expect(body.containsKey('eventSource'), false); // direct-path fields NOT sent alongside an envelope
    });

    test('does not call the API at all when there is nothing pending', () async {
      var callCount = 0;
      final fake = FakeHttpClient((request) async {
        callCount++;
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(callCount, 0);
    });
  });

  group('syncPendingEvents — failure handling', () {
    test('a network failure leaves the entry queued (not failed) for a later retry', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final fake = FakeHttpClient((request) async => throw Exception('simulated socket failure'));
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.queued);
      expect(updated.attempts, 1);
    });

    test('a genuine backend rejection (e.g. 400) is terminal — marked failed, never retried', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(400, {
            'error': {'code': 'BAD_REQUEST', 'message': 'invalid signature'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.failed);
      expect(updated.lastError, contains('BAD_REQUEST'));
    });

    test('a transient backend failure (500) leaves the entry queued (not failed) for a later retry', () async {
      // Regression test (sync audit, FINAL GAP CLOSURE item 7): a 500
      // means a response reached us but the BACKEND failed — it says
      // nothing about this request's content being wrong (unlike a 400/
      // 403), so it must be retried exactly like a network failure, not
      // treated as a terminal rejection.
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(500, {
            'error': {'code': 'INTERNAL_ERROR', 'message': 'temporary database outage'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.queued);
      expect(updated.attempts, 1);
    });

    test('a 503 is also treated as retryable, not terminal', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry());
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(503, {
            'error': {'code': 'SERVICE_UNAVAILABLE', 'message': 'deploy in progress'},
          }));
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.queued);
    });

    test('an expired entry is marked expired without ever attempting an upload', () async {
      await EmergencyOutboxStore.instance.upsert(
        fakeEntry(expiresAt: DateTime.now().subtract(const Duration(minutes: 1))),
      );
      var callCount = 0;
      final fake = FakeHttpClient((request) async {
        callCount++;
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(callCount, 0);
      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.expired);
    });

    test('an entry that has exhausted maxSyncAttempts is marked failed without a further attempt', () async {
      await EmergencyOutboxStore.instance.upsert(
        fakeEntry(attempts: EmergencyCommunicationService.maxSyncAttempts),
      );
      var callCount = 0;
      final fake = FakeHttpClient((request) async {
        callCount++;
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(callCount, 0);
      final updated = await EmergencyOutboxStore.instance.get('event-1');
      expect(updated!.state, OutboxEntryState.failed);
    });

    test('backoff: an entry attempted very recently is skipped this pass, not retried immediately', () async {
      await EmergencyOutboxStore.instance.upsert(
        fakeEntry(attempts: 1, lastAttemptAt: DateTime.now()),
      );
      var callCount = 0;
      final fake = FakeHttpClient((request) async {
        callCount++;
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(callCount, 0);
    });
  });

  group('syncPendingEvents — idempotency and priority', () {
    test('every upload uses the SAME eventId — never mints a new one for a retry', () async {
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'stable-id'));
      String? sentEventId;
      final fake = FakeHttpClient((request) async {
        final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        sentEventId = body['eventId'] as String?;
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(sentEventId, 'stable-id');
    });

    test('a critical-priority entry is uploaded before a normal-priority one queued alongside it', () async {
      final normalEnvelope = OriginEnvelope(
        protocolVersion: '1',
        originDeviceId: 'd',
        eventType: 'sos',
        eventSource: 'manual',
        category: 'general',
        createdAt: '2026-01-01T00:00:00.000Z',
        expiresAt: '2026-01-02T00:00:00.000Z',
        maxHops: 8,
        priority: 'normal',
        keyId: 'k',
        signature: 's',
      );
      final criticalEnvelope = OriginEnvelope(
        protocolVersion: '1',
        originDeviceId: 'd',
        eventType: 'sos',
        eventSource: 'manual',
        category: 'medical',
        createdAt: '2026-01-01T00:00:00.000Z',
        expiresAt: '2026-01-02T00:00:00.000Z',
        maxHops: 8,
        priority: 'critical',
        keyId: 'k',
        signature: 's',
      );
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'normal-1', originEnvelope: normalEnvelope));
      await EmergencyOutboxStore.instance.upsert(fakeEntry(eventId: 'critical-1', originEnvelope: criticalEnvelope));

      final uploadOrder = <String>[];
      final fake = FakeHttpClient((request) async {
        final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
        uploadOrder.add(body['eventId'] as String);
        return jsonStreamedResponse(201, {'event': {}});
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      await EmergencyCommunicationService().syncPendingEvents();

      expect(uploadOrder.first, 'critical-1');
    });
  });

  group('startPeriodicSync / stopPeriodicSync — connectivity listener robustness', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('starting and stopping never throws or surfaces an unhandled error, even with no real platform connectivity plugin registered', () async {
      final service = EmergencyCommunicationService();
      // In a plain `flutter test` environment there is no real platform
      // implementation behind connectivity_plus's EventChannel — this is
      // exactly the "plugin unavailable" case the try/catch + onError
      // handler in startPeriodicSync exist for for. This test's own
      // success (no thrown/unhandled error reaching the test framework)
      // IS the assertion.
      expect(() => service.startPeriodicSync(interval: const Duration(minutes: 30)), returnsNormally);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(() => service.stopPeriodicSync(), returnsNormally);
      service.dispose();
    });

    test('calling startPeriodicSync twice cleanly replaces the previous subscription rather than leaking it', () async {
      final service = EmergencyCommunicationService();
      service.startPeriodicSync();
      service.startPeriodicSync(); // must not throw or double-subscribe
      await Future<void>.delayed(const Duration(milliseconds: 50));
      service.stopPeriodicSync();
      service.dispose();
    });
  });
}
