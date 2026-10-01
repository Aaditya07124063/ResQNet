import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/core/services/profile_service.dart';
import 'package:resqnet/core/services/sensor_recorder_service.dart';
import 'package:resqnet/core/services/trusted_contacts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sensor recordings (contain GPS) expire on the device', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('resqnet_sessions'));
    tearDown(() async => dir.delete(recursive: true));

    Future<File> file(String name, DateTime modified) async {
      final f = File('${dir.path}/$name')..writeAsStringSync('{}');
      await f.setLastModified(modified);
      return f;
    }

    test('files at or past the retention age are deleted; newer ones stay', () async {
      final now = DateTime(2026, 9, 28, 12);
      final old = await file('old.json', now.subtract(const Duration(days: 31)));
      final boundary = await file('boundary.json', now.subtract(SensorRecorderService.sessionRetention));
      final recent = await file('recent.json', now.subtract(const Duration(days: 29)));

      final deleted = await SensorRecorderService.pruneFilesOlderThan(dir, SensorRecorderService.sessionRetention, now: now);

      expect(deleted, 2);
      expect(old.existsSync(), isFalse);
      expect(boundary.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      // Idempotent.
      expect(await SensorRecorderService.pruneFilesOlderThan(dir, SensorRecorderService.sessionRetention, now: now), 0);
    });

    test('a missing directory is not an error', () async {
      expect(await SensorRecorderService.pruneFilesOlderThan(Directory('${dir.path}/nope'), const Duration(days: 1)), 0);
    });
  });

  group('explicit sign-out clears personal data from memory and disk', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('profile (including medical details)', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(ProfileService.storageKey, '{"name":"Asha","bloodGroup":"O+","allergies":"penicillin"}');
      await prefs.setBool(ProfileService.includeMedicalInAutoSosKey, true);
      final profile = ProfileService();
      await profile.loadFromCache();
      expect(profile.bloodGroup, 'O+');
      expect(profile.includeMedicalInAutoSos, isTrue);

      await profile.clearLocal();

      expect(profile.bloodGroup, isEmpty);
      expect(profile.allergies, isEmpty);
      expect(prefs.getString(ProfileService.storageKey), isNull);
      // The medical-sharing opt-in is reset with the rest of the profile.
      expect(profile.includeMedicalInAutoSos, isFalse);
      expect(profile.automaticSosMedicalSummary, isEmpty);
      expect(prefs.getBool(ProfileService.includeMedicalInAutoSosKey), isNull);
    });

    test('trusted contacts', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TrustedContactsService.storageKey, '[]');
      final contacts = TrustedContactsService();
      await contacts.clearLocal();
      expect(contacts.contacts, isEmpty);
      expect(prefs.getString(TrustedContactsService.storageKey), isNull);
    });
  });
}
