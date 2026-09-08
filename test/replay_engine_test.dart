import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/models/recorded_sample.dart';
import 'package:resqnet/core/models/recorded_session.dart';
import 'package:resqnet/core/services/replay_engine.dart';

RecordedSample sampleAt(DateTime t, {double linearMag = 0.3}) => RecordedSample(
      timestamp: t,
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
      orientation: 'face_up',
      drivingContextState: 'stationary',
      earthquakeDetectorState: 'normal',
      crashDetectorState: 'normal',
    );

void main() {
  final base = DateTime(2026, 1, 1);

  RecordedSession sessionWithSamples(int count, {int gapMs = 20}) =>
      RecordedSession(
        sessionId: 'replay-test',
        startTime: base,
        devicePlatform: 'android',
        samplingRateHz: 1000 ~/ gapMs,
        samples: List.generate(
            count, (i) => sampleAt(base.add(Duration(milliseconds: i * gapMs)),
                linearMag: i.toDouble())),
      );

  group('ReplayEngine ordering', () {
    test('emits samples in exactly the recorded order', () async {
      final session = sessionWithSamples(10);
      final engine = ReplayEngine(session);
      final received = <double>[];
      final sub = engine.stream.listen((s) => received.add(s.linearAccelZ));

      await engine.play(speedMultiplier: 1000); // fast, deterministic order
      await sub.cancel();
      await engine.dispose();

      expect(received, List.generate(10, (i) => i.toDouble()));
    });

    test('an empty session completes immediately with nothing emitted',
        () async {
      final session = sessionWithSamples(0);
      final engine = ReplayEngine(session);
      final received = <double>[];
      final sub = engine.stream.listen((s) => received.add(s.linearAccelZ));

      await engine.play();
      await sub.cancel();
      await engine.dispose();

      expect(received, isEmpty);
      expect(engine.samplesEmitted, 0);
    });
  });

  group('ReplayEngine timing/control', () {
    test('speedMultiplier scales real elapsed time between samples',
        () async {
      // 5 samples, 40ms apart in the recording = 160ms of recorded time.
      // At 4x speed that should take roughly 40ms of real wall time.
      final session = sessionWithSamples(5, gapMs: 40);
      final engine = ReplayEngine(session);
      final stopwatch = Stopwatch()..start();
      await engine.play(speedMultiplier: 4.0);
      stopwatch.stop();
      await engine.dispose();

      expect(stopwatch.elapsedMilliseconds, greaterThan(20));
      expect(stopwatch.elapsedMilliseconds, lessThan(120));
    });

    test('stop() ends playback before the last sample is reached', () async {
      final session = sessionWithSamples(50, gapMs: 20);
      final engine = ReplayEngine(session);
      final received = <double>[];
      final sub = engine.stream.listen((s) => received.add(s.linearAccelZ));

      final playFuture = engine.play(speedMultiplier: 1.0);
      await Future.delayed(const Duration(milliseconds: 60));
      engine.stop();
      await playFuture;
      await sub.cancel();
      await engine.dispose();

      expect(received.length, lessThan(50));
      expect(engine.isPlaying, isFalse);
    });

    test('rejects a non-positive speedMultiplier', () async {
      final engine = ReplayEngine(sessionWithSamples(3));
      expect(() => engine.play(speedMultiplier: 0),
          throwsA(isA<ArgumentError>()));
      await engine.dispose();
    });

    test('calling play() while already playing is a no-op, not a restart',
        () async {
      final session = sessionWithSamples(20, gapMs: 20);
      final engine = ReplayEngine(session);
      final first = engine.play(speedMultiplier: 1.0);
      // Second call should return immediately without starting a
      // concurrent playback loop.
      await engine.play(speedMultiplier: 1.0);
      engine.stop();
      await first;
      await engine.dispose();
    });
  });

  group('ReplayEngine corrupted/empty session handling', () {
    test('a session parsed from corrupted JSON never reaches the engine — '
        'RecordedSession.fromJsonString throws first', () {
      expect(() => RecordedSession.fromJsonString('{bad json'),
          throwsA(isA<SessionFormatException>()));
    });

    test('replaying an empty session does not throw', () async {
      final engine = ReplayEngine(sessionWithSamples(0));
      await expectLater(engine.play(), completes);
      await engine.dispose();
    });
  });
}
