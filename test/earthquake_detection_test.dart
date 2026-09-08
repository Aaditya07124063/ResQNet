import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/models/earthquake_config.dart';
import 'package:resqnet/core/models/earthquake_evidence.dart';
import 'package:resqnet/core/models/sensor_sample.dart';
import 'package:resqnet/core/services/seismic_service.dart';

/// False-positive/true-positive suite for the earthquake detector.
///
/// Uses a compressed-timescale EarthquakeConfig (a ~1.2s LTA window
/// instead of production's 30s) so tests run in real time quickly. The
/// STA/LTA methodology itself is real: each scenario first establishes a
/// genuine quiet baseline (filling the long window) before introducing
/// the event — exactly how a real STA/LTA detector is meant to be
/// exercised, not a shortcut around it.
void main() {
  late EarthquakeConfig fastConfig;

  setUp(() {
    fastConfig = const EarthquakeConfig(
      shortWindowSamples: 6,
      longWindowSamples: 60,
      minimumSustainedDuration: Duration(milliseconds: 150),
      reAlertCooldown: Duration.zero,
    );
  });

  SensorSample sample(double magnitude, {double gyroMag = 0}) => SensorSample(
        timestamp: DateTime.now(),
        accelX: 0,
        accelY: 0,
        accelZ: 9.8 + magnitude,
        linearAccelX: 0,
        linearAccelY: 0,
        linearAccelZ: magnitude,
        gyroX: gyroMag,
        gyroY: 0,
        gyroZ: 0,
      );

  Future<EarthquakeEvidence> run(
    List<double> magnitudes, {
    List<double>? gyroMags,
    EarthquakeConfig? config,
  }) async {
    final controller = StreamController<SensorSample>();
    final service = SeismicService(
      config: config ?? fastConfig,
      verboseLogging: false,
      debugSampleStream: controller.stream,
    );
    service.start();

    for (var i = 0; i < magnitudes.length; i++) {
      controller.add(sample(magnitudes[i],
          gyroMag: gyroMags != null && i < gyroMags.length ? gyroMags[i] : 0));
      await Future.delayed(const Duration(milliseconds: 20));
    }
    await Future.delayed(const Duration(milliseconds: 100));

    final evidence = service.evidence;
    service.stop();
    await controller.close();
    return evidence;
  }

  List<double> quietBaseline(int count) => List.filled(count, 0.05);

  group('scenarios that must NOT trigger an earthquake alert', () {
    test('phone lying on a table (near-zero noise)', () async {
      final e = await run(quietBaseline(70));
      expect(e.totalConfidence, 0.0);
    });

    test('single short tap/knock (one impulse, not sustained/oscillatory)',
        () async {
      final e = await run([...quietBaseline(60), 3.0, ...quietBaseline(10)]);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('continuous vibration (motorcycle/walking — never actually still)',
        () async {
      // LTA never gets a quiet baseline, so the stationary gate blocks
      // evaluation the whole time — this is the exact false-positive
      // ResQNet's old 10s-window STA/LTA was vulnerable to.
      final e = await run(List.filled(80, 1.2));
      expect(e.totalConfidence, 0.0);
    });

    test('phone in a pocket (low, muffled, non-oscillatory movement)',
        () async {
      final e = await run([...quietBaseline(60), ...List.filled(10, 0.6)]);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test(
        'phone pickup: resting quietly then picked up — strong gyro '
        'rotation accompanies the accel jitter (must be REJECTED by gyro, '
        'regardless of how oscillatory the accel signal looks)', () async {
      // A hand grabbing/reorienting a resting phone: multi-directional
      // accel jitter (satisfies the old oscillation-only gate) PLUS a
      // large, sustained gyro rotation (the actual physical fingerprint
      // that separates this from ground shaking).
      final pickupAccel =
          List.generate(14, (i) => i.isEven ? 0.2 : 1.8); // oscillatory-ish
      final pickupGyro = List.filled(14, 3.0); // deliberate rotation, rad/s
      final e = await run(
        [...quietBaseline(60), ...pickupAccel],
        gyroMags: [...List.filled(60, 0.0), ...pickupGyro],
      );
      expect(e.rejectedByGyro, isTrue);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });
  });

  group('scenario that MUST trigger an earthquake alert', () {
    test('sustained oscillating shaking after a quiet baseline', () async {
      // A longer LTA window than the other tests (300 samples vs 60) so
      // the sustained shake itself (60 samples ~1.2s) doesn't contaminate
      // its own baseline mid-event the way it would with a window barely
      // longer than the event — production uses a 1500-sample (~30s) LTA
      // against a 2-5s quake for the same reason; this keeps that
      // long-event-vs-short-window ratio intact while staying fast.
      final longConfig = EarthquakeConfig(
        shortWindowSamples: fastConfig.shortWindowSamples,
        longWindowSamples: 300,
        minimumSustainedDuration: fastConfig.minimumSustainedDuration,
        reAlertCooldown: fastConfig.reAlertCooldown,
      );
      final oscillation = List.generate(
          60, (i) => i.isEven ? 0.1 : 2.5); // alternating low/high magnitude
      final e = await run(
        [...quietBaseline(300), ...oscillation],
        config: longConfig,
      );
      expect(e.rejectedByGyro, isFalse);
      expect(e.oscillationCount, greaterThanOrEqualTo(longConfig.minimumOscillations));
      expect(e.cumulativeAbsoluteVelocity, greaterThanOrEqualTo(longConfig.minimumCav));
      expect(e.totalConfidence, greaterThanOrEqualTo(longConfig.confirmationThreshold));
    });
  });
}
