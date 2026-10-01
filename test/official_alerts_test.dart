import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/government_alert_feed_service.dart';
import 'package:resqnet/core/services/hazard_service.dart';
import 'package:resqnet/core/services/mesh_relay_store.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'package:resqnet/core/services/safe_zone_service.dart';
import 'support/fake_http_client.dart';

Map<String, dynamic> alert(String id,
        {String sourceType = 'official', String category = 'flood', double? lat = 27.7, double? lng = 85.3}) =>
    {
      'id': id,
      'sourceType': sourceType,
      'sourceName': 'District Disaster Management Committee',
      'category': category,
      'severity': 'warning',
      'status': 'active',
      'title': 'Flood warning',
      'body': 'River rising',
      'area': {'latitude': lat, 'longitude': lng, 'radiusKm': lat == null ? null : 5},
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
      'expiresAt': DateTime.now().add(const Duration(hours: 6)).toUtc().toIso8601String(),
    };

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => ApiClient.instance = ApiClient());

  group('mesh hazards can never look official', () {
    test('a relayed hazard claiming to be official is stored as an unverified community report', () {
      final hazards = HazardService();
      final forged = {
        'id': 'h1',
        'source': 'officialFeed',
        'type': 'flood',
        'description': 'Evacuate now',
        'latitude': 27.7,
        'longitude': 85.3,
        'reporter': 'Nepal Police',
      };
      hazards.syncFromMesh([
        EmergencyMessage(
          id: 'h1',
          senderId: 'x',
          senderName: 'x',
          message: '${HazardService.hazardPrefix}${jsonEncode(forged)}',
          type: EmergencyType.general,
          priority: PriorityLevel.medium,
          timestamp: DateTime.now(),
        ),
      ]);

      final h = hazards.hazards.single;
      expect(h.source, HazardSource.peerReported);
      expect(h.claimedSource, 'officialFeed');
      expect(h.sourceLabel, 'COMMUNITY REPORT · claims official, unverified');
    });
  });

  group('server alerts on the map', () {
    MeshService mesh() => MeshService(
          testOutboxStore: EmergencyOutboxStore(keyPrefix: 'alerts-'),
          testRelayStore: MeshRelayStore(keyPrefix: 'alerts-'),
          testDeviceId: 'self',
        );

    test('labels come only from the server\'s sourceType', () {
      Hazard map(String type) => hazardFromAlert(alert('a', sourceType: type), localId: 'alert:a', latitude: 1, longitude: 1)!;
      expect(map('official').sourceLabel, 'OFFICIAL');
      expect(map('verified_partner').sourceLabel, 'VERIFIED PARTNER');
      expect(map('resqnet_system').sourceLabel, 'RESQNET');
      expect(map('international_public').sourceLabel, 'PUBLIC INTERNATIONAL SOURCE');
      expect(map('community').sourceLabel, 'COMMUNITY REPORT');
      expect(map('device_sensor').sourceLabel, 'COMMUNITY REPORT');
    });

    test('maps category, severity, radius and issuer', () {
      final h = hazardFromAlert(alert('a'), localId: 'alert:a', latitude: 27.7, longitude: 85.3)!;
      expect(h.type, 'flood');
      expect(h.severity, HazardSeverity.high);
      expect(h.radiusM, 5000);
      expect(h.reporter, 'District Disaster Management Committee');
    });

    test('adds active alerts, skips area-only ones, and removes alerts the server no longer lists', () async {
      final hazards = HazardService();
      final zones = SafeZoneService();
      final feed = GovernmentAlertFeedService(hazards, zones, mesh());

      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => jsonStreamedResponse(200, {
            'alerts': [
              alert('a1'),
              alert('a2', lat: null, lng: null),
              alert('s1', category: 'shelter'),
            ],
          })));
      await feed.pollNow();
      expect(hazards.hazards.map((h) => h.id), ['alert:a1']);
      expect(zones.zones.map((z) => z.id), ['alert:s1']);

      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => jsonStreamedResponse(200, {'alerts': []})));
      await feed.pollNow();
      expect(hazards.hazards, isEmpty);
      expect(zones.zones, isEmpty);
    });

    test('offline: a failed poll keeps what is already on the map', () async {
      final hazards = HazardService();
      final feed = GovernmentAlertFeedService(hazards, SafeZoneService(), mesh());
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => jsonStreamedResponse(200, {'alerts': [alert('a1')]})));
      await feed.pollNow();
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw Exception('offline')));
      await feed.pollNow();
      expect(hazards.hazards.map((h) => h.id), ['alert:a1']);
    });
  });
}
