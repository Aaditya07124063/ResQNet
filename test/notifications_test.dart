import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/notifications/notification_catalog.dart';
import 'package:resqnet/core/services/notification_service.dart';

const sosEventId = '11111111-1111-4111-8111-111111111111';
const clientEventId = '33333333-3333-4333-8333-333333333333';

EmergencyMessage meshMessage({
  String id = clientEventId,
  PriorityLevel priority = PriorityLevel.critical,
  String? cancels,
  String senderName = 'Hiker A',
}) =>
    EmergencyMessage(
      id: id,
      senderId: 'u',
      senderName: senderName,
      message: 'trapped near the bridge',
      type: EmergencyType.trapped,
      priority: priority,
      timestamp: DateTime.now(),
      cancelsEventId: cancels,
    );

void main() {
  group('push mapping and priority', () {
    test('a trusted contact SOS is critical, deep-links to the alert detail, and keeps coordinates', () {
      final spec = specForPush({
        'type': 'sos_trusted_contact',
        'sosEventId': sosEventId,
        'eventId': clientEventId,
        'latitude': '27.7172',
        'longitude': '85.3240',
      }, title: '🚨 Asha needs you', body: 'help')!;

      expect(spec.kind, ResQNetNotificationKind.trustedContactSos);
      expect(spec.channel, ResQNetChannel.sos);
      expect(spec.channel.level, NotificationLevel.critical);
      expect(spec.destination, NotificationDestination.alertDetail);
      expect(spec.params['latitude'], '27.7172');
      expect(spec.dedupKey, 'sos:$clientEventId');
    });

    test('a nearby SOS deep-links to the privacy-limited nearby view', () {
      final spec = specForPush({'type': 'sos_nearby', 'sosEventId': sosEventId, 'eventId': clientEventId})!;
      expect(spec.destination, NotificationDestination.nearbyEmergency);
      expect(spec.params, {'sosEventId': sosEventId});
      expect(spec.params.containsKey('latitude'), isFalse);
    });

    test('an earthquake alert is high (not critical) priority and deduplicated per area per hour', () {
      final a = specForPush({'type': 'earthquake_corroborated', 'latitude': '27.7', 'longitude': '85.3'})!;
      final b = specForPush({'type': 'earthquake_corroborated', 'latitude': '27.7', 'longitude': '85.3'})!;
      expect(a.channel, ResQNetChannel.alerts);
      expect(a.channel.level, NotificationLevel.high);
      expect(a.dedupKey, b.dedupKey);
    });

    test('a resolution update is normal priority and replaces the original SOS alert slot', () {
      final spec = specForPush({'type': 'sos_resolved', 'sosEventId': sosEventId, 'eventId': clientEventId})!;
      expect(spec.channel.level, NotificationLevel.normal);
      expect(spec.tag, 'sos:$clientEventId');
      expect(spec.dedupKey, isNot(spec.tag));
    });

    test('untrusted payloads: malformed ids and coordinates are rejected, never routed', () {
      expect(specForPush({'type': 'sos_nearby', 'sosEventId': '../../admin'}), isNull);
      final spec = specForPush({
        'type': 'sos_trusted_contact',
        'eventId': clientEventId,
        'latitude': '999',
        'longitude': 'javascript:alert(1)',
      })!;
      expect(spec.params.containsKey('latitude'), isFalse);
      expect(spec.params.containsKey('sosEventId'), isFalse);
    });
  });

  group('mesh mapping', () {
    test('a received SOS is critical and deep-links to the received-emergency detail', () {
      final spec = specForMeshMessage(meshMessage())!;
      expect(spec.kind, ResQNetNotificationKind.meshSos);
      expect(spec.channel, ResQNetChannel.sos);
      expect(spec.destination, NotificationDestination.meshEmergency);
      expect(spec.params['eventId'], clientEventId);
    });

    test('the same SOS by mesh and by push shares one dedup key and display slot', () {
      final mesh = specForMeshMessage(meshMessage())!;
      final push = specForPush({'type': 'sos_nearby', 'sosEventId': sosEventId, 'eventId': clientEventId})!;
      expect(mesh.dedupKey, push.dedupKey);
      expect(mesh.tag, push.tag);
      expect(mesh.notificationId, push.notificationId);
    });

    test('low-priority mesh messages ("I am safe") do not notify', () {
      expect(specForMeshMessage(meshMessage(priority: PriorityLevel.low)), isNull);
    });

    test('a medium-priority mesh alert is a hazard alert, not an SOS', () {
      final spec = specForMeshMessage(meshMessage(priority: PriorityLevel.medium))!;
      expect(spec.kind, ResQNetNotificationKind.hazardAlert);
      expect(spec.channel, ResQNetChannel.alerts);
    });

    test('an unverified cancellation never produces an all-clear', () {
      final notice = meshMessage(id: sosEventId, priority: PriorityLevel.high, cancels: clientEventId);
      expect(specForMeshMessage(notice), isNull);
      final verified = specForMeshMessage(notice, cancellationVerified: true)!;
      expect(verified.kind, ResQNetNotificationKind.sosResolved);
      expect(verified.tag, 'sos:$clientEventId');
    });

    test('a signed SOS envelope is treated as an SOS even if its relayed priority was lowered', () {
      final envelope = OriginEnvelope(
        protocolVersion: '1',
        originDeviceId: 'd',
        eventType: 'sos',
        eventSource: 'manual',
        category: 'trapped',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)).toIso8601String(),
        maxHops: 8,
        priority: 'critical',
        keyId: 'k',
        signature: 's',
      );
      final spec = specForMeshMessage(EmergencyMessage(
        id: clientEventId,
        senderId: 'u',
        senderName: '',
        message: '',
        type: EmergencyType.general,
        priority: PriorityLevel.low,
        timestamp: DateTime.now(),
        originEnvelope: envelope,
      ))!;
      expect(spec.kind, ResQNetNotificationKind.meshSos);
      expect(spec.title, contains('Someone nearby'));
    });
  });

  group('deep-link payloads', () {
    test('payloads round-trip to their destination', () {
      final spec = specForMeshMessage(meshMessage())!;
      final parsed = parseNotificationPayload(spec.payload);
      expect(parsed.destination, NotificationDestination.meshEmergency);
      expect(parsed.params['eventId'], clientEventId);
    });

    test('garbage payloads fall back to Home', () {
      for (final payload in [null, '', 'not json', '[]', '{"destination":"deleteEverything"}']) {
        expect(parseNotificationPayload(payload).destination, NotificationDestination.home);
      }
    });

    test('notification ids are stable across runs and within Android int range', () {
      expect(stableNotificationId('sos:abc'), stableNotificationId('sos:abc'));
      expect(stableNotificationId('sos:abc'), isNot(stableNotificationId('sos:abd')));
      expect(stableNotificationId('x' * 500), inInclusiveRange(0, 0x7fffffff));
    });

    test('the crash/earthquake warning uses the detection channel and returns to Home', () {
      final spec = detectionWarningSpec(detection: 'crash', seconds: 30);
      expect(spec.channel, ResQNetChannel.detection);
      expect(spec.body, contains('30 seconds'));
      expect(spec.destination, NotificationDestination.home);
    });
  });

  group('channels', () {
    test('channel ids are unique and the detection channel keeps its original id', () {
      final ids = ResQNetChannel.all.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ResQNetChannel.detection.id, 'resqnet_emergency');
    });

    test('not every channel is maximum priority', () {
      expect(ResQNetChannel.all.where((c) => c.level == NotificationLevel.critical).length,
          lessThan(ResQNetChannel.all.length));
    });
  });

  group('deduplication store', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('an event notifies once, including after a restart', () async {
      expect(await NotificationDedupStore().markIfNew('sos:1'), isTrue);
      expect(await NotificationDedupStore().markIfNew('sos:1'), isFalse, reason: 'persisted across instances');
      expect(await NotificationDedupStore().markIfNew('sos:2'), isTrue);
    });

    test('concurrent arrivals of the same event notify once', () async {
      final store = NotificationDedupStore();
      final results = await Future.wait([store.markIfNew('sos:1'), store.markIfNew('sos:1'), store.markIfNew('sos:1')]);
      expect(results.where((r) => r), hasLength(1));
    });

    test('storage stays bounded', () async {
      final store = NotificationDedupStore(maxEntries: 5);
      for (var i = 0; i < 20; i++) {
        await store.markIfNew('k$i');
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('resqnet_notification_keys_v1')!.split('"k').length - 1, 5);
    });
  });
}
