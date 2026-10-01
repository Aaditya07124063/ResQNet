import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/sos_alert.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/ai_service.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/emergency_communication_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/location_service.dart';
import 'package:resqnet/core/services/sos_service.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

/// Records every backend request; [respond] decides each outcome.
class Backend {
  final requests = <(String, String, Map<String, dynamic>?)>[];
  Future<http.StreamedResponse> Function(http.Request request) respond =
      (_) async => throw const SocketException('Failed host lookup: api.resqnet.co');

  FakeHttpClient client() => FakeHttpClient((request) async {
        final r = request as http.Request;
        requests.add((r.method, r.url.path, r.body.isEmpty ? null : jsonDecode(r.body) as Map<String, dynamic>));
        return respond(r);
      });

  Iterable<(String, String, Map<String, dynamic>?)> calls(String method, String pathSuffix) =>
      requests.where((r) => r.$1 == method && r.$2.endsWith(pathSuffix));
}

Future<http.StreamedResponse> accepted(http.Request r) async => r.method == 'POST'
    ? jsonStreamedResponse(201, {
        'event': {'id': 'server-row', 'originVerificationState': 'not_applicable'}
      })
    : jsonStreamedResponse(200, {'event': {}});

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  late FakeDeviceKeyChannel keys;
  late FakeSecureStorage secureStorage;
  late Backend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    keys = FakeDeviceKeyChannel(keyId: 'sos-lifecycle-key');
    DeviceKeyService.instance.resetCacheForTests();
    await TokenStorage.instance.save(accessToken: 'access', refreshToken: 'refresh');
    backend = Backend();
    ApiClient.instance = ApiClient(httpClient: backend.client());
  });

  tearDown(() {
    keys.dispose();
    secureStorage.dispose();
    DeviceKeyService.instance.resetCacheForTests();
    ApiClient.instance = ApiClient();
  });

  SosService newService() => SosService(AiService(), LocationService(), restoreOnCreate: false);

  Future<SosAlert> trigger(SosService service, {String source = 'manual'}) => service.triggerSos(
        userId: 'user-1',
        userName: 'Hiker A',
        category: SosCategory.trapped,
        message: 'stuck on the trail',
        eventSource: source,
      );

  group('activation and duplicate protection', () {
    test('starts idle, then becomes active with a persisted outbox entry', () async {
      final service = newService();
      expect(service.sosActive, isFalse);

      final alert = await trigger(service);

      expect(service.sosActive, isTrue);
      expect(service.activeAlert!.id, alert.id);
      expect(await EmergencyOutboxStore.instance.get(alert.id), isNotNull);
    });

    test('a second trigger while active returns the same SOS and creates nothing new', () async {
      final service = newService();
      final first = await trigger(service);
      final second = await trigger(service, source: 'crash_detection');

      expect(second.id, first.id);
      expect(await EmergencyOutboxStore.instance.loadAll(), hasLength(1));
    });

    test('simultaneous triggers (double tap) create exactly one SOS', () async {
      final service = newService();
      final results = await Future.wait([trigger(service), trigger(service), trigger(service)]);

      expect(results.map((a) => a.id).toSet(), hasLength(1));
      expect(await EmergencyOutboxStore.instance.loadAll(), hasLength(1));
    });

    test('offline: the backend attempt fails but the SOS stays queued for retry', () async {
      final service = newService();
      final alert = await trigger(service);
      await settle();

      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.state, OutboxEntryState.queued);
      expect(entry.attempts, 1);
      expect(entry.mayHaveReachedServer, isFalse, reason: 'a DNS failure means the request never left the phone');
    });

    test('an active SOS survives an app restart; a resolved one does not come back', () async {
      final first = newService();
      final alert = await trigger(first);

      final restarted = newService();
      await restarted.restore();
      expect(restarted.activeAlert?.id, alert.id);

      await restarted.cancelActiveSos(SosResolution.resolved);
      final afterCancel = newService();
      await afterCancel.restore();
      expect(afterCancel.sosActive, isFalse);
    });
  });

  test('an SOS pressed right after a restart re-uses the restored active SOS instead of orphaning it', () async {
    final before = newService();
    final original = await trigger(before);

    // New process: restore starts in the constructor and the user presses
    // SOS before it has finished.
    final restarted = SosService(AiService(), LocationService());
    final pressed = await trigger(restarted);

    expect(pressed.id, original.id);
    expect(await EmergencyOutboxStore.instance.loadAll(), hasLength(1));
  });

  group('cancellation', () {
    test('cancelled before the server ever saw it: never uploaded, even when back online', () async {
      final service = newService();
      final alert = await trigger(service);
      await settle(); // first attempt fails before connecting

      final outcome = await service.cancelActiveSos(SosResolution.falseAlarm);
      expect(outcome!.remoteState, ResolutionSyncState.notNeeded);
      expect(service.sosActive, isFalse);

      backend.respond = accepted;
      await EmergencyCommunicationService().syncPendingEvents();

      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.state, OutboxEntryState.cancelledBeforeUpload);
      expect(entry.resolution, SosResolution.falseAlarm);
      expect(backend.calls('POST', '/sos').length, 1, reason: 'only the original failed attempt');
      expect(backend.calls('PATCH', '/sos/${alert.id}'), isEmpty);
    });

    test('cancelled after the server accepted it: the server is told immediately', () async {
      backend.respond = accepted;
      final service = newService();
      final alert = await trigger(service);
      await settle();

      final outcome = await service.cancelActiveSos(SosResolution.resolved);

      expect(outcome!.remoteState, ResolutionSyncState.synced);
      final patch = backend.calls('PATCH', '/sos/${alert.id}').single;
      expect(patch.$3, {'status': 'resolved'});
    });

    test('cancelled while offline after acceptance: pending, then synced when back online', () async {
      backend.respond = accepted;
      final service = newService();
      final alert = await trigger(service);
      await settle();

      backend.respond = (_) async => throw const SocketException('Failed host lookup: api.resqnet.co');
      final outcome = await service.cancelActiveSos(SosResolution.resolved);
      expect(outcome!.remoteState, ResolutionSyncState.pending);

      backend.respond = accepted;
      await EmergencyCommunicationService().syncPendingEvents();

      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.resolutionSync, ResolutionSyncState.synced);
    });

    test('a request that may have reached the server is resolved remotely, not silently dropped', () async {
      // A timeout-style failure: the request may have been delivered.
      backend.respond = (_) async => throw const SocketException('Connection reset by peer');
      final service = newService();
      final alert = await trigger(service);
      await settle();

      await service.cancelActiveSos(SosResolution.resolved);
      var entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.state, isNot(OutboxEntryState.cancelledBeforeUpload));
      expect(entry.resolutionSync, ResolutionSyncState.pending);

      // Time passes beyond the retry backoff, and the connection returns.
      await EmergencyOutboxStore.instance.update(
        alert.id,
        (e) => e.copyWith(lastAttemptAt: DateTime.now().subtract(const Duration(hours: 1))),
      );
      backend.respond = accepted;
      await EmergencyCommunicationService().syncPendingEvents();
      entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.state, OutboxEntryState.serverAccepted);
      expect(entry.resolutionSync, ResolutionSyncState.synced);
    });

    test('cancelling with no active SOS does nothing', () async {
      expect(await newService().cancelActiveSos(SosResolution.resolved), isNull);
    });

    test('the mesh cancellation notice references the SOS and signs that reference', () async {
      final service = newService();
      final alert = await trigger(service);
      final notice = await service.cancellationBroadcastMessage(alert, 'Hiker A', SosResolution.resolved);

      expect(notice.cancelsEventId, alert.id);
      expect(notice.id, isNot(alert.id));
      expect(notice.originEnvelope?.message, cancellationSignedText(alert.id));
      expect(notice.toJson().toString(), isNot(contains('access')), reason: 'no tokens in mesh payloads');
    });
  });

  group('history', () {
    test('local history includes offline and cancelled SOS, newest first', () async {
      final service = newService();
      final first = await trigger(service);
      await settle();
      await service.cancelActiveSos(SosResolution.falseAlarm);
      final second = await trigger(service);

      final history = await service.localHistory();
      expect(history.map((e) => e.eventId).toList(), [second.id, first.id]);
      expect(history.last.resolution, SosResolution.falseAlarm);
    });
  });

  test('the SOS broadcast is never relayed below high priority', () async {
    final service = newService();
    final alert = await trigger(service);
    final message = await service.sosToBroadcastMessage(alert, 'Hiker A');
    expect(message.priority, anyOf(PriorityLevel.critical, PriorityLevel.high));
  });
}
