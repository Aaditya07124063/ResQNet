import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/models/crash_config.dart';
import 'package:resqnet/core/models/crash_evidence.dart';
import 'package:resqnet/core/models/sensor_sample.dart';
import 'package:resqnet/core/services/crash_detection_service.dart';
import 'package:resqnet/core/services/driving_context_service.dart';

/// False-positive/true-positive suite for the crash detector.
///
/// Uses a compressed-timescale CrashConfig (milliseconds instead of
/// seconds for the observation/stillness windows) so each scenario runs
/// in real wall-clock time — samples are actually delivered at ~50Hz with
/// real `Future.delayed` gaps between them, exercising the genuine
/// stillness-accumulation and gyro/speed-drop logic, just compressed.
/// The algorithm under test is identical to production; only the window
/// durations are shortened for test speed.
void main() {
  late CrashConfig fastConfig;

  setUp(() {
    fastConfig = const CrashConfig(
      postImpactWindow: Duration(milliseconds: 300),
      postImpactStillnessRequired: Duration(milliseconds: 60),
      speedDropWindow: Duration(milliseconds: 300),
    );
  });

  /// Feeds [samples] at ~50Hz real intervals into a fresh
  /// CrashDetectionService, waits for the observation window to close,
  /// and returns the resulting evidence. If [speedDropAfterSamples] is
  /// set, [postSpeedMps] is applied to the (real, GPS-evidence-marked)
  /// driving context after that many samples — simulating a genuine
  /// measured deceleration partway through the observation window, the
  /// way a real collision's GPS speed actually behaves.
  Future<CrashEvidence> run(
    List<SensorSample> samples, {
    required DrivingContext context,
    double speedMps = 0,
    int? speedDropAfterSamples,
    double postSpeedMps = 0,
  }) async {
    final controller = StreamController<SensorSample>();
    final drivingContext = DrivingContextService();
    drivingContext.debugSetContext(context, speedMps: speedMps);

    final service = CrashDetectionService(
      config: fastConfig,
      drivingContext: drivingContext,
      verboseLogging: false,
      debugSampleStream: controller.stream,
    );
    service.start();

    for (var i = 0; i < samples.length; i++) {
      controller.add(samples[i]);
      await Future.delayed(const Duration(milliseconds: 20));
      if (speedDropAfterSamples != null && i == speedDropAfterSamples) {
        drivingContext.debugSetContext(context, speedMps: postSpeedMps);
      }
    }
    // Let the observation window close and evaluate.
    await Future.delayed(fastConfig.postImpactWindow + const Duration(milliseconds: 100));

    final evidence = service.evidence;
    service.stop();
    await controller.close();
    return evidence;
  }

  SensorSample sample({
    double linearMag = 0,
    double gyroMag = 0,
    double rawAccelZ = 9.8,
  }) =>
      SensorSample(
        timestamp: DateTime.now(),
        accelX: 0,
        accelY: 0,
        accelZ: rawAccelZ,
        linearAccelX: 0,
        linearAccelY: 0,
        linearAccelZ: linearMag,
        gyroX: gyroMag,
        gyroY: 0,
        gyroZ: 0,
      );

  List<SensorSample> steady(double magnitude, int count) =>
      List.generate(count, (_) => sample(linearMag: magnitude));

  /// A sample whose RAW acceleration (not just linear/gravity-removed) is
  /// near zero — the weightlessness signature of an object in free-fall.
  List<SensorSample> freefall(int count) =>
      List.generate(count, (_) => sample(linearMag: 0, rawAccelZ: 0.2));

  group('scenarios that must NOT confirm a crash', () {
    test('phone lying on a table (near-zero noise)', () async {
      final e = await run(steady(0.1, 10), context: DrivingContext.stationary);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('small table vibration', () async {
      final e = await run(steady(1.5, 15), context: DrivingContext.stationary);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('user picking up the phone (moderate, brief, no vehicle context)',
        () async {
      final e = await run(
        [...steady(0.2, 5), sample(linearMag: 6), ...steady(0.2, 5)],
        context: DrivingContext.stationary,
      );
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('user shaking the phone hard on a desk (no vehicle context)',
        () async {
      // A hard desk-shake can spike acceleration well past the candidate
      // gate — this is exactly the case CrashConfig.noVehicleContextScoreCap
      // exists for.
      final e = await run(
        [...List.generate(10, (i) => sample(linearMag: i.isEven ? 30 : -30))],
        context: DrivingContext.stationary,
      );
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
      expect(e.accelerationScore, lessThanOrEqualTo(fastConfig.noVehicleContextScoreCap));
    });

    test('walking (rhythmic, low amplitude)', () async {
      final e = await run(
        List.generate(20, (i) => sample(linearMag: i.isEven ? 2.0 : -1.5)),
        context: DrivingContext.walking,
      );
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('phone dropped straight down (big spike, no vehicle context)',
        () async {
      final e = await run(
        [...steady(0.5, 5), sample(linearMag: 45), ...steady(0.5, 10)],
        context: DrivingContext.stationary,
      );
      // Even a huge spike can't cross the threshold without vehicle
      // context — this is the acceleration-score hard cap doing its job.
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test(
        'genuine free-fall drop: weightless period then impact, no vehicle '
        'evidence at all (must classify PHONE_DROP, must NOT confirm)',
        () async {
      final e = await run(
        [
          ...steady(0.2, 5), // resting in hand
          ...freefall(6), // airborne — raw accel near 0
          sample(linearMag: 60, gyroMag: 9.0, rawAccelZ: 9.8), // floor impact
          ...steady(0.1, 20), // settles, motionless on the floor
        ],
        context: DrivingContext.stationary,
      );
      expect(e.precededByFreefall, isTrue);
      expect(e.hasIndependentVehicleEvidence, isFalse);
      expect(e.classification, 'PHONE_DROP');
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test(
        'phone drop while vehicle context is active but GPS shows NO speed '
        'drop (vehicle context alone must not be sufficient)',
        () async {
      // Phone slips off the passenger seat while the car cruises at a
      // constant speed — vehicle context, gyro tumble and post-impact
      // stillness are all present, but nothing about the vehicle's own
      // motion changed. Must not confirm without a real measured Δv.
      final e = await run(
        [
          ...steady(2, 5), // vehicle context established (see speedMps)
          ...freefall(6),
          sample(linearMag: 60, gyroMag: 9.0, rawAccelZ: 9.8),
          ...steady(0.1, 20),
        ],
        context: DrivingContext.vehicle,
        speedMps: 20, // constant — never actually drops
      );
      expect(e.hasIndependentVehicleEvidence, isFalse);
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('phone rotating in hand (gyro only, no linear spike)', () async {
      final e = await run(
        List.generate(10, (_) => sample(linearMag: 1.0, gyroMag: 8.0)),
        context: DrivingContext.stationary,
      );
      // Never even reaches the impact-candidate gate on acceleration.
      expect(e.totalConfidence, 0.0);
    });

    test('normal driving, mild road noise', () async {
      final e = await run(
        steady(2.0, 20),
        context: DrivingContext.vehicle,
        speedMps: 15,
      );
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('hard braking (deceleration, no sharp linear spike)', () async {
      final e = await run(
        steady(6.0, 15), // ~0.6g — real braking, below the candidate gate
        context: DrivingContext.vehicle,
        speedMps: 12,
      );
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });

    test('pothole / speed bump (brief moderate jolt while still moving)',
        () async {
      final e = await run(
        [...steady(2, 5), sample(linearMag: 20), ...steady(3, 10)],
        context: DrivingContext.vehicle,
        speedMps: 10,
      );
      // Crosses the candidate gate but the vehicle keeps moving normally
      // afterward — no post-impact stillness, no gyro, no speed drop.
      expect(e.totalConfidence, lessThan(fastConfig.confirmationThreshold));
    });
  });

  group('scenario that MUST confirm a crash', () {
    test(
        'simulated collision: vehicle context + spike + gyro + stillness + '
        'a REAL measured GPS speed drop', () async {
      final samples = [
        ...steady(2, 5), // driving normally
        sample(linearMag: 55, gyroMag: 6.0), // impact
        ...steady(0.2, 20), // post-impact stillness
      ];
      final e = await run(
        samples,
        context: DrivingContext.vehicle,
        speedMps: 20,
        // Speed collapses right after the impact sample (index 5) — a
        // genuine measured deceleration, not just vehicle context.
        speedDropAfterSamples: 5,
        postSpeedMps: 1.0,
      );
      expect(e.hasIndependentVehicleEvidence, isTrue);
      expect(e.classification, 'VEHICLE_EVENT');
      expect(e.totalConfidence, greaterThanOrEqualTo(fastConfig.confirmationThreshold));
    });
  });
}
