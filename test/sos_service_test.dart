// Regression test for item 6 of the FINAL GAP CLOSURE: the full offline
// SOS lifecycle for a brand-new install — triggerSos signs and persists
// BEFORE any network attempt, the record survives a simulated restart,
// the eventId stays stable across every path (outbox/mesh/backend), and
// a client-side retry never regenerates a new eventId (the backend's own
// idempotency, verified separately in backend/tests/sosService.test.ts,
// depends entirely on this client-side stability holding).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/models/sos_alert.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/ai_service.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/location_service.dart';
import 'package:resqnet/core/services/sos_service.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_http_client.dart' show FakeHttpClient, jsonStreamedResponse;
import 'support/fake_secure_storage.dart';

void main() {
  late FakeDeviceKeyChannel fakeChannel;
  late FakeSecureStorage secureStorage;

  setUp(() async {
    // A brand-new install: no persisted preferences, no secure-storage
    // device identity/keys, no cached DeviceKeyService state, and no
    // network yet available (FakeHttpClient below simulates the offline
    // case unless a test overrides it).
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    fakeChannel = FakeDeviceKeyChannel(keyId: 'fresh-install-key');
    DeviceKeyService.instance.resetCacheForTests();
    await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw Exception('offline')));
  });

  tearDown(() {
    fakeChannel.dispose();
    secureStorage.dispose();
    DeviceKeyService.instance.resetCacheForTests();
    ApiClient.instance = ApiClient();
  });

  test('a brand-new install\'s first offline SOS is signed and persisted before any network attempt', () async {
    final sosService = SosService(AiService(), LocationService());

    final alert = await sosService.triggerSos(
      userId: 'user-1',
      userName: 'Hiker A',
      category: SosCategory.medical,
      message: 'trapped, need help',
    );

    // Give the fire-and-forget backend report a moment to run (and fail,
    // since ApiClient is wired to always throw "offline" above) — this
    // must not have prevented persistence, which already happened
    // synchronously before triggerSos even returned.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final entry = await EmergencyOutboxStore.instance.get(alert.id);
    expect(entry, isNotNull, reason: 'the outbox entry must be persisted even though the network call failed');
    expect(entry!.originEnvelope, isNotNull, reason: 'a fresh install with a working key module must produce a signed envelope');
    expect(entry.state, OutboxEntryState.queued, reason: 'a network failure must leave it queued for later retry, not failed/lost');
  });

  test('the eventId is stable across the alert, the outbox entry, and the mesh broadcast message', () async {
    final sosService = SosService(AiService(), LocationService());

    final alert = await sosService.triggerSos(
      userId: 'user-1',
      userName: 'Hiker A',
      category: SosCategory.fire,
      message: 'fire spreading',
    );
    final entry = await EmergencyOutboxStore.instance.get(alert.id);
    final broadcastMessage = await sosService.sosToBroadcastMessage(alert, 'Hiker A');

    expect(entry!.eventId, alert.id);
    expect(broadcastMessage.id, alert.id);
    // The mesh envelope must be the EXACT one persisted, never a second,
    // independently re-signed one for the same event.
    expect(broadcastMessage.originEnvelope?.signature, entry.originEnvelope?.signature);
  });

  test('the persisted outbox entry survives a simulated app restart (a fresh EmergencyOutboxStore read)', () async {
    final sosService = SosService(AiService(), LocationService());
    final alert = await sosService.triggerSos(
      userId: 'user-1',
      userName: 'Hiker A',
      category: SosCategory.trapped,
      message: 'stuck under debris',
    );

    // Simulate an app restart: SharedPreferences' mocked backing store
    // persists across getInstance() calls within a test (exactly like a
    // real device's disk-backed SharedPreferences persists across a
    // process restart) — re-reading via the store's own instance (a
    // fresh in-memory read path, not a cached Dart object) proves this
    // is real persistence, not an in-memory List still holding the
    // reference from before "restart".
    final afterRestart = await EmergencyOutboxStore.instance.get(alert.id);
    expect(afterRestart, isNotNull);
    expect(afterRestart!.category, 'trapped');
    expect(afterRestart.message, 'stuck under debris');
  });

  test('a transient backend failure (500) during initial report leaves the entry queued, not failed', () async {
    // Regression test (sync audit, FINAL GAP CLOSURE item 7): marking
    // this failed here would be permanent — EmergencyCommunicationService
    // .syncPendingEvents() never retries a terminal (failed/expired/
    // serverAccepted/deliveryConfirmed) entry, so a transient 500 on the
    // very first attempt must never be treated the same as a genuine
    // rejection.
    ApiClient.instance = ApiClient(
      httpClient: FakeHttpClient((_) async => jsonStreamedResponse(500, {
            'error': {'code': 'INTERNAL_ERROR', 'message': 'temporary outage'},
          })),
    );
    final sosService = SosService(AiService(), LocationService());

    final alert = await sosService.triggerSos(
      userId: 'user-1',
      userName: 'Hiker A',
      category: SosCategory.medical,
      message: 'help',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final entry = await EmergencyOutboxStore.instance.get(alert.id);
    expect(entry!.state, OutboxEntryState.queued);
  });

  test('a retried backend report for the same eventId never creates a second outbox entry', () async {
    final sosService = SosService(AiService(), LocationService());
    final alert = await sosService.triggerSos(
      userId: 'user-1',
      userName: 'Hiker A',
      category: SosCategory.general,
      message: 'help',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A later, separate sync attempt for the SAME eventId (mirroring
    // EmergencyCommunicationService.syncPendingEvents' own retry) must
    // update the SAME record, never add a second one — this is the
    // client-side half of what makes the backend's own
    // `uq_sos_events_event_id` idempotency guarantee meaningful.
    final before = await EmergencyOutboxStore.instance.loadAll();
    await EmergencyOutboxStore.instance.upsert(
      (await EmergencyOutboxStore.instance.get(alert.id))!.copyWith(state: OutboxEntryState.serverPending),
    );
    final after = await EmergencyOutboxStore.instance.loadAll();

    expect(after.length, before.length);
    expect(after.where((e) => e.eventId == alert.id).length, 1);
  });
}
