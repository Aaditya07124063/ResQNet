import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:resqnet/core/models/recorded_sample.dart';
import 'package:resqnet/core/models/recorded_session.dart';
import 'package:resqnet/core/models/sensor_sample.dart';
import 'package:resqnet/core/services/sensor_recorder_service.dart';

/// Points getApplicationDocumentsDirectory() at a real temp directory
/// instead of hitting a platform channel that doesn't exist under
/// `flutter test` — SensorRecorderService's storage methods (save/load/
/// list/delete/export) are exercised against this for real, just in a
/// throwaway location.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this.tempDir);
  final Directory tempDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => tempDir.path;
}

RecordedSample sampleAt(int i, {double linearMag = 0.5}) => RecordedSample(
      timestamp: DateTime(2026, 1, 1).add(Duration(milliseconds: i * 20)),
      accelX: 0,
      accelY: 0,
      accelZ: 9.8 + linearMag,
      linearAccelX: 0,
      linearAccelY: 0,
      linearAccelZ: linearMag,
      gravityX: 0,
      gravityY: 0,
      gravityZ: 9.8,
      gyroX: 0,
      gyroY: 0,
      gyroZ: 0,
      gpsSpeedMps: null,
      gpsAccuracy: null,
      latitude: null,
      longitude: null,
      orientation: 'face_up',
      drivingContextState: 'stationary',
      earthquakeDetectorState: 'normal',
      crashDetectorState: 'normal',
      crashConfidence: 0.0,
      earthquakeConfidence: 0.0,
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('resqnet_recorder_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('RecordedSample/RecordedSession serialization (pure, no I/O)', () {
    test('round-trips every field through toJson/fromJson', () {
      final sample = RecordedSample(
            timestamp: DateTime(2026, 1, 1),
            accelX: 1,
            accelY: 2,
            accelZ: 3,
            linearAccelX: 4,
            linearAccelY: 5,
            linearAccelZ: 6,
            gravityX: 7,
            gravityY: 8,
            gravityZ: 9,
            gyroX: 10,
            gyroY: 11,
            gyroZ: 12,
            gpsSpeedMps: 13.5,
            gpsAccuracy: 2.1,
            latitude: 27.7,
            longitude: 85.3,
            orientation: 'portrait_upright',
            drivingContextState: 'vehicle',
            earthquakeDetectorState: 'candidate',
            crashDetectorState: 'possibleImpact',
            crashConfidence: 0.42,
            earthquakeConfidence: 0.77,
          );

      final restored = RecordedSample.fromJson(sample.toJson());
      expect(restored.timestamp, sample.timestamp);
      expect(restored.accelX, sample.accelX);
      expect(restored.gravityZ, sample.gravityZ);
      expect(restored.gyroY, sample.gyroY);
      expect(restored.gpsSpeedMps, sample.gpsSpeedMps);
      expect(restored.latitude, sample.latitude);
      expect(restored.orientation, sample.orientation);
      expect(restored.drivingContextState, sample.drivingContextState);
      expect(restored.crashConfidence, sample.crashConfidence);
    });

    test('null GPS/confidence fields survive a round trip as null', () {
      final sample = sampleAt(0);
      final restored = RecordedSample.fromJson(sample.toJson());
      expect(restored.gpsSpeedMps, isNull);
      expect(restored.latitude, isNull);
    });

    test('RecordedSession round-trips through toJsonString/fromJsonString',
        () {
      final session = RecordedSession(
        sessionId: 'test-session-1',
        startTime: DateTime(2026, 1, 1),
        endTime: DateTime(2026, 1, 1, 0, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
        labels: const ['phone_pickup'],
        samples: List.generate(5, sampleAt),
      );

      final restored = RecordedSession.fromJsonString(session.toJsonString());
      expect(restored.sessionId, session.sessionId);
      expect(restored.samplingRateHz, 25);
      expect(restored.labels, ['phone_pickup']);
      expect(restored.samples.length, 5);
      expect(restored.samples.first.timestamp, session.samples.first.timestamp);
    });

    test('an empty-sample session is valid, not corrupted', () {
      final session = RecordedSession(
        sessionId: 'empty-session',
        startTime: DateTime(2026, 1, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
      );
      final restored = RecordedSession.fromJsonString(session.toJsonString());
      expect(restored.samples, isEmpty);
      expect(restored.toCsv(), RecordedSample.csvHeader); // header only
    });

    test('toCsv produces one row per sample plus the header', () {
      final session = RecordedSession(
        sessionId: 's',
        startTime: DateTime(2026, 1, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
        samples: List.generate(3, sampleAt),
      );
      final lines = session.toCsv().split('\n');
      expect(lines.length, 4); // header + 3 rows
      expect(lines.first, RecordedSample.csvHeader);
    });

    test('fromJsonString throws SessionFormatException on invalid JSON syntax',
        () {
      expect(() => RecordedSession.fromJsonString('{not valid json'),
          throwsA(isA<SessionFormatException>()));
    });

    test('fromJsonString throws SessionFormatException when "samples" is missing',
        () {
      expect(
          () => RecordedSession.fromJsonString(
              '{"sessionId":"x","startTime":"2026-01-01T00:00:00.000",'
              '"devicePlatform":"android","samplingRateHz":25}'),
          throwsA(isA<SessionFormatException>()));
    });

    test('fromJsonString throws SessionFormatException on a malformed sample',
        () {
      expect(
          () => RecordedSession.fromJsonString(
              '{"sessionId":"x","startTime":"2026-01-01T00:00:00.000",'
              '"devicePlatform":"android","samplingRateHz":25,'
              '"samples":[{"timestamp":"2026-01-01T00:00:00.000"}]}'),
          throwsA(isA<SessionFormatException>()));
    });

    test('fromJsonString rejects a non-object top-level value', () {
      expect(() => RecordedSession.fromJsonString('[1,2,3]'),
          throwsA(isA<SessionFormatException>()));
    });
  });

  group('SensorRecorderService recording', () {
    SensorSample sensorSample(int i, {double linearMag = 0.3}) => SensorSample(
          timestamp: DateTime.now(),
          accelX: 0,
          accelY: 0,
          accelZ: 9.8 + linearMag,
          linearAccelX: 0,
          linearAccelY: 0,
          linearAccelZ: linearMag,
          gyroX: 0,
          gyroY: 0,
          gyroZ: 0,
        );

    Future<RecordedSession> recordSamples(
      int count, {
      int recordEveryNth = 2,
      int maxSamples = 15000,
    }) async {
      final controller = StreamController<SensorSample>();
      final recorder = SensorRecorderService(
        recordEveryNth: recordEveryNth,
        maxSamples: maxSamples,
        debugSampleStream: controller.stream,
      );
      await recorder.startRecording(labels: const ['unit_test']);
      for (var i = 0; i < count; i++) {
        controller.add(sensorSample(i));
        await Future.delayed(const Duration(milliseconds: 1));
      }
      final session = await recorder.stopRecording();
      await controller.close();
      return session!;
    }

    test('downsamples: recordEveryNth=2 keeps every other sample', () async {
      final session = await recordSamples(20, recordEveryNth: 2);
      expect(session.samples.length, 10);
      expect(session.samplingRateHz, 25); // 50/2
    });

    test('recordEveryNth=1 keeps every sample', () async {
      final session = await recordSamples(10, recordEveryNth: 1);
      expect(session.samples.length, 10);
      expect(session.samplingRateHz, 50);
    });

    test('samples come out in the order they were fed in', () async {
      final session = await recordSamples(10, recordEveryNth: 1);
      for (var i = 1; i < session.samples.length; i++) {
        expect(
            session.samples[i].timestamp.isAfter(session.samples[i - 1].timestamp) ||
                session.samples[i].timestamp
                    .isAtSameMomentAs(session.samples[i - 1].timestamp),
            isTrue);
      }
    });

    test('recording auto-stops at maxSamples', () async {
      final session = await recordSamples(30, recordEveryNth: 1, maxSamples: 5);
      expect(session.samples.length, 5);
    });

    test('with no injected detectors, state fields default sensibly',
        () async {
      final session = await recordSamples(4, recordEveryNth: 1);
      final s = session.samples.first;
      expect(s.crashDetectorState, 'inactive');
      expect(s.earthquakeDetectorState, 'inactive');
      expect(s.drivingContextState, 'unknown');
      expect(s.crashConfidence, isNull);
    });

    test('stopRecording when not recording returns null', () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      expect(await recorder.stopRecording(), isNull);
    });

    test('saveSession/loadSession round-trip via disk', () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      final session = RecordedSession(
        sessionId: 'disk-roundtrip',
        startTime: DateTime(2026, 1, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
        samples: List.generate(3, sampleAt),
      );
      await recorder.saveSession(session);
      final loaded = await recorder.loadSession('disk-roundtrip');
      expect(loaded.samples.length, 3);
      expect(loaded.sessionId, 'disk-roundtrip');
    });

    test('listSavedSessionIds finds saved sessions; deleteSession removes them',
        () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      final session = RecordedSession(
        sessionId: 'list-test',
        startTime: DateTime(2026, 1, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
        samples: List.generate(2, sampleAt),
      );
      await recorder.saveSession(session);
      expect(await recorder.listSavedSessionIds(), contains('list-test'));

      await recorder.deleteSession('list-test');
      expect(await recorder.listSavedSessionIds(), isNot(contains('list-test')));
    });

    test('loadSession throws SessionFormatException for an unknown id',
        () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      expect(() => recorder.loadSession('does-not-exist'),
          throwsA(isA<SessionFormatException>()));
    });

    test('exportSessionAsCsv writes a CSV file with the expected header',
        () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      final session = RecordedSession(
        sessionId: 'csv-test',
        startTime: DateTime(2026, 1, 1),
        devicePlatform: 'android',
        samplingRateHz: 25,
        samples: List.generate(2, sampleAt),
      );
      await recorder.saveSession(session);
      final path = await recorder.exportSessionAsCsv('csv-test');
      final contents = await File(path).readAsString();
      expect(contents.split('\n').first, RecordedSample.csvHeader);
      expect(contents.split('\n').length, 3); // header + 2 rows
    });

    test('loading a corrupted session file on disk throws SessionFormatException',
        () async {
      final recorder = SensorRecorderService(debugSampleStream: const Stream.empty());
      final dir = Directory('${tempDir.path}/resqnet_sensor_sessions');
      await dir.create(recursive: true);
      await File('${dir.path}/broken.json').writeAsString('{not valid json');
      expect(() => recorder.loadSession('broken'),
          throwsA(isA<SessionFormatException>()));
    });
  });
}
