import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/security/alert_signature.dart';
import 'package:resqnet/core/services/hazard_service.dart';

// Uses the SAME fixture as backend/tests/alertSignature.test.ts, so passing
// here proves the Dart canonical form matches the server byte for byte.
final fixture = jsonDecode(File('test/fixtures/signed_alert.json').readAsStringSync()) as Map<String, dynamic>;
final publicKey = fixture['publicKeyPem'] as String;
Map<String, dynamic> copy(String key) => jsonDecode(jsonEncode(fixture[key])) as Map<String, dynamic>;

EmergencyMessage meshHazard(Map<String, dynamic> hazardJson) => EmergencyMessage(
      id: hazardJson['id'] as String,
      senderId: 'relay',
      senderName: 'relay',
      message: '${HazardService.hazardPrefix}${jsonEncode(hazardJson)}',
      type: EmergencyType.general,
      priority: PriorityLevel.high,
      timestamp: DateTime.now(),
    );

Map<String, dynamic> relayedCopy(Map<String, dynamic> signedAlert) => Hazard.fromServerAlert(signedAlert)!.toJson();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('server alert signatures (cross-checked with the backend)', () {
    test('the server-signed fixture verifies', () {
      expect(verifyServerAlert(copy('alert'), publicKeyPem: publicKey), isTrue);
    });

    test('an altered alert fails', () {
      for (final change in <String, Object>{'title': 'All clear', 'sourceType': 'community', 'status': 'resolved'}.entries) {
        final altered = copy('alert')..[change.key] = change.value;
        expect(verifyServerAlert(altered, publicKeyPem: publicKey), isFalse, reason: change.key);
      }
    });

    test('no pinned key or no signature means unverified', () {
      expect(verifyServerAlert(copy('alert')), isFalse, reason: 'no key pinned in the test build');
      expect(verifyServerAlert(copy('alert')..remove('signature'), publicKeyPem: publicKey), isFalse);
    });
  });

  group('official alerts relayed over the mesh', () {
    test('a correctly signed official alert keeps its OFFICIAL label on the receiving phone', () {
      final hazards = HazardService(alertPublicKeyPem: publicKey);
      hazards.syncFromMesh([meshHazard(relayedCopy(copy('alert')))]);
      final h = hazards.hazards.single;
      expect(h.source, HazardSource.officialFeed);
      expect(h.sourceLabel, 'OFFICIAL');
      expect(h.description, startsWith('Flood warning: river rising'));
    });

    test('changing the relayed copy\'s visible text does not change what is shown (rebuilt from the signed alert)', () {
      final hazards = HazardService(alertPublicKeyPem: publicKey);
      final json = relayedCopy(copy('alert'))..['description'] = 'Everything is fine, go home';
      hazards.syncFromMesh([meshHazard(json)]);
      expect(hazards.hazards.single.description, startsWith('Flood warning'));
    });

    test('an altered signed alert is shown as an unverified community report', () {
      final hazards = HazardService(alertPublicKeyPem: publicKey);
      final signed = copy('alert');
      final json = relayedCopy(signed)..['signedAlert'] = (copy('alert')..['severity'] = 'info');
      hazards.syncFromMesh([meshHazard(json)]);
      final h = hazards.hazards.single;
      expect(h.source, HazardSource.peerReported);
      expect(h.sourceLabel, contains('unverified'));
    });

    test('an older signed version never replaces a newer one (replay protection)', () {
      final hazards = HazardService(alertPublicKeyPem: publicKey);
      hazards.syncFromMesh([meshHazard(relayedCopy(copy('alert')))]);
      hazards.syncFromMesh([meshHazard(relayedCopy(copy('olderVersion')))]);
      expect(hazards.hazards.single.severity, HazardSeverity.high);
    });

    test('a verified newer version replaces an unverified community copy of the same alert', () {
      final hazards = HazardService(alertPublicKeyPem: publicKey);
      final forged = relayedCopy(copy('alert'))
        ..remove('signedAlert')
        ..['description'] = 'forged';
      hazards.syncFromMesh([meshHazard(forged)]);
      expect(hazards.hazards.single.source, HazardSource.peerReported);
      hazards.syncFromMesh([meshHazard(relayedCopy(copy('alert')))]);
      expect(hazards.hazards.single.source, HazardSource.officialFeed);
    });
  });
}
