import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/models/emergency_message.dart';
import 'package:resqnet/core/models/origin_envelope.dart';
import 'package:resqnet/core/models/sos_alert.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/core/services/ai_service.dart';
import 'package:resqnet/core/services/device_key_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/location_service.dart';
import 'package:resqnet/core/services/mesh_service.dart';
import 'package:resqnet/core/services/profile_service.dart';
import 'package:resqnet/core/services/sos_dispatch_service.dart';
import 'package:resqnet/core/services/sos_service.dart';
import 'package:resqnet/features/profile/medical_sharing_setting.dart';
import 'support/fake_device_key_channel.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';
import 'support/real_crypto_test_helpers.dart';

const medicalKeys = ['bloodGroup', 'allergies', 'medications'];
const summary = '\nBlood: O+ | Allergies: penicillin';

EmergencyMessage meshText({double? lat, double? lng, String text = 'road blocked near bridge'}) => EmergencyMessage(
      id: '1700000000000',
      senderId: 'user-a',
      senderName: 'Asha',
      message: text,
      type: EmergencyType.general,
      priority: PriorityLevel.medium,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );

Uint8List bytesOf(Map<String, dynamic> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  late EmergencyOutboxStore store;
  late List<Map<String, dynamic>> sent;

  MeshService device() => MeshService(
        testOutboxStore: store,
        testDeviceId: 'device-self',
        testSendBytes: (peer, bytes) async => sent.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>),
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = EmergencyOutboxStore(keyPrefix: 'test-');
    sent = [];
  });

  group('ordinary mesh messages carry no medical data', () {
    test('a mesh text message and a location share have no medical fields at all', () {
      for (final msg in [meshText(), meshText(text: '📍 Sharing my location', lat: 27.7172, lng: 85.324)]) {
        final json = msg.toJson();
        for (final key in medicalKeys) {
          expect(json.containsKey(key), isFalse, reason: key);
        }
      }
    });

    test('medical fields from older app versions are dropped: not shown, not passed on', () async {
      final legacy = meshText().toJson()
        ..['bloodGroup'] = 'O+'
        ..['allergies'] = 'penicillin'
        ..['medications'] = 'warfarin';
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(legacy));
      expect(mesh.messages, hasLength(1));
      final stored = jsonEncode(mesh.messages.single.toJson());
      expect(stored, isNot(contains('penicillin')));
      expect(stored, isNot(contains('warfarin')));
      for (final payload in sent) {
        expect(jsonEncode(payload), isNot(matches(RegExp('penicillin|warfarin|O\\+'))));
      }
    });

    test('the mesh and dashboard screens never read medical details for a broadcast', () {
      for (final path in ['lib/features/mesh/mesh_screen.dart', 'lib/features/dashboard/dashboard_screen.dart']) {
        final source = File(path).readAsStringSync();
        expect(source, isNot(matches(RegExp(r'profile\.(bloodGroup|allergies|medications)'))), reason: path);
      }
    });
  });

  group('"Include medical information in automatic SOS" preference', () {
    Future<ProfileService> profileWith(Map<String, Object> prefs) async {
      SharedPreferences.setMockInitialValues({
        'profile_cache': jsonEncode({'name': 'Asha', 'bloodGroup': 'O+', 'allergies': 'penicillin', 'medications': 'warfarin'}),
        ...prefs,
      });
      final profile = ProfileService();
      await profile.loadFromCache();
      return profile;
    }

    test('is OFF by default, even with medical details in the profile', () async {
      final profile = await profileWith({});
      expect(profile.bloodGroup, 'O+');
      expect(profile.includeMedicalInAutoSos, isFalse);
      expect(profile.automaticSosMedicalSummary, isEmpty);
    });

    test('ON adds blood group and allergies — never medications — and survives a restart', () async {
      final profile = await profileWith({});
      await profile.setIncludeMedicalInAutoSos(true);
      expect(profile.automaticSosMedicalSummary, summary);
      expect(profile.automaticSosMedicalSummary, isNot(contains('warfarin')));

      final restarted = ProfileService();
      await restarted.loadFromCache();
      expect(restarted.includeMedicalInAutoSos, isTrue);
    });

    test('anything but a stored true counts as OFF', () async {
      final profile = await profileWith({ProfileService.includeMedicalInAutoSosKey: 'true'});
      expect(profile.includeMedicalInAutoSos, isFalse);
    });
  });

  group('automatic SOS', () {
    late FakeSecureStorage secure;
    late FakeDeviceKeyChannel keys;

    setUp(() async {
      secure = FakeSecureStorage();
      keys = FakeDeviceKeyChannel(keyId: 'medical-test-key');
      DeviceKeyService.instance.resetCacheForTests();
      await TokenStorage.instance.save(accessToken: 'a', refreshToken: 'r');
      ApiClient.instance = ApiClient(httpClient: FakeHttpClient((_) async => throw const SocketException('offline')));
    });

    tearDown(() {
      keys.dispose();
      secure.dispose();
      DeviceKeyService.instance.resetCacheForTests();
      ApiClient.instance = ApiClient();
    });

    Future<SosAlert> trigger({required String medical}) =>
        SosService(AiService(), LocationService(), restoreOnCreate: false).triggerSos(
          userId: 'user-1',
          userName: 'Asha',
          category: SosCategory.rescue,
          message: 'VEHICLE CRASH DETECTED — AUTO SOS',
          eventSource: 'crash_detection',
          medicalSummary: medical,
        );

    test('OFF: nothing medical in the SOS, its signed envelope or the outbox', () async {
      final alert = await trigger(medical: '');
      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(alert.message, isNot(contains('Blood')));
      expect(entry.message, isNot(contains('Blood')));
      expect(entry.originEnvelope!.message, isNot(contains('Blood')));
    });

    test('ON: the medical summary is part of the signed message', () async {
      final alert = await trigger(medical: summary);
      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(alert.message, endsWith(summary));
      expect(entry.originEnvelope, isNotNull);
      expect(entry.originEnvelope!.message, alert.message);
    });

    test('ON but the device cannot sign: the medical summary is left out', () async {
      keys.throwOnSign = PlatformException(code: 'KEY_UNAVAILABLE');
      final alert = await trigger(medical: summary);
      final entry = (await EmergencyOutboxStore.instance.get(alert.id))!;
      expect(entry.originEnvelope, isNull);
      expect(alert.message, isNot(contains('Blood')));
      expect(entry.message, isNot(contains('Blood')));
    });

    test('the pre-filled SMS never contains the medical summary', () {
      final alert = SosAlert(
        id: 'e1',
        userId: 'user-1',
        userName: 'Asha',
        category: SosCategory.rescue,
        message: 'VEHICLE CRASH DETECTED — AUTO SOS$summary',
        timestamp: DateTime.now(),
        status: SosStatus.active,
      );
      final body = SosDispatchService.sosSmsBody(alert: alert, userName: 'Asha', baseMessage: 'VEHICLE CRASH DETECTED — AUTO SOS');
      expect(body, isNot(matches(RegExp('Blood|penicillin'))));
    });
  });

  group('integrity of signed SOS content on the mesh (real ECDSA signatures)', () {
    const eventId = '33333333-3333-4333-8333-333333333333';
    const signedText = 'VEHICLE CRASH DETECTED — AUTO SOS$summary';

    Map<String, dynamic> signedSos(TestKeyPair signer) {
      final envelope = buildRealSignedEnvelopeForTests(signer: signer, eventId: eventId, message: signedText);
      return EmergencyMessage(
        id: eventId,
        senderId: 'user-a',
        senderName: 'Asha',
        message: signedText,
        type: EmergencyType.rescue,
        priority: PriorityLevel.critical,
        latitude: 27.7172,
        longitude: 85.324,
        timestamp: DateTime.now(),
        originEnvelope: envelope,
        expiresAt: DateTime.parse(envelope.expiresAt),
      ).toJson();
    }

    test('an unmodified signed SOS is accepted and shows exactly the signed text', () async {
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(signedSos(generateTestKeyPair())));
      expect(mesh.messages.single.message, signedText);
      expect(mesh.messages.single.originVerifiedLocally, isTrue);
    });

    test('a relay that edits the displayed medical details is rejected', () async {
      final tampered = signedSos(generateTestKeyPair())
        ..['message'] = 'VEHICLE CRASH DETECTED — AUTO SOS\nBlood: AB- | Allergies: none';
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(tampered));
      expect(mesh.messages, isEmpty);
    });

    test('a relay that edits the signed envelope as well fails the signature check', () async {
      final json = signedSos(generateTestKeyPair());
      const forged = 'VEHICLE CRASH DETECTED — AUTO SOS\nBlood: AB- | Allergies: none';
      final envelope = (json['originEnvelope'] as Map<String, dynamic>)..['message'] = forged;
      json
        ..['message'] = forged
        ..['originEnvelope'] = OriginEnvelope.fromJson(envelope).toJson();
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(json));
      expect(mesh.messages, isEmpty);
    });

    test('a relay that moves the displayed location is rejected', () async {
      final tampered = signedSos(generateTestKeyPair())..['latitude'] = 27.9;
      final mesh = device();
      await mesh.handleIncomingPayloadForTesting(bytesOf(tampered));
      expect(mesh.messages, isEmpty);
    });
  });

  group('settings UI', () {
    testWidgets('the switch is OFF by default, explains what is shared, and persists when turned on', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final profile = ProfileService();
      await tester.runAsync(profile.loadMedicalSharingPreference);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: profile,
        child: const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MedicalSharingSetting()))),
      ));

      expect(tester.widget<Switch>(find.byKey(const Key('medical-auto-sos-switch'))).value, isFalse);
      expect(find.text('Include medical information in automatic SOS'), findsOneWidget);
      for (final line in MedicalSharingSetting.explanation) {
        expect(find.text(line), findsOneWidget);
      }
      expect(find.textContaining('Your medications are never included'), findsOneWidget);
      expect(find.textContaining('never include medical information'), findsOneWidget);

      await tester.tap(find.byKey(const Key('medical-auto-sos-switch')));
      await tester.pumpAndSettle();
      expect(profile.includeMedicalInAutoSos, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(ProfileService.includeMedicalInAutoSosKey), isTrue);
    });
  });
}
