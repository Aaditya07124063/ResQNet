import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../models/crash_config.dart';
import '../models/crash_evidence.dart';
import '../models/detection_event.dart';
import '../models/sensor_sample.dart';
import 'detection_logging_service.dart';
import 'driving_context_service.dart';
import 'motion_sensor_service.dart';

/// Multi-signal crash detector.
///
/// A single acceleration spike is never enough on its own — see
/// [_onSample] for the actual gate. Every candidate impact is scored
/// across acceleration, gyroscope rotation, GPS speed drop, driving
/// context, and post-impact stillness (see [CrashEvidence]/[CrashConfig])
/// before the user is ever shown a confirmation prompt, and even that
/// prompt requires an explicit action or a timeout before SOS fires —
/// never an instant, unconfirmed alert.
///
/// Pipeline: RAW SENSOR → gravity removal (done once, shared, in
/// MotionSensorService) → impact candidate gate → driving-context check
/// → short observation window (gyro peak, GPS speed drop, post-impact
/// stillness) → weighted confidence → state machine → (only on
/// CRASH_CONFIRMED) the existing SosDispatchService flow, unchanged.
class CrashDetectionService extends ChangeNotifier {
  final CrashConfig config;
  final DrivingContextService drivingContext;
  final DetectionLoggingService? logger;
  final bool verboseLogging;

  /// Test-only: supply a synthetic sample stream instead of the real
  /// shared MotionSensorService (which needs the real sensors_plus
  /// platform channel and can't run under `flutter test`). Leave null in
  /// production — this is how CrashDetectionServiceTest and the
  /// false-positive suite drive the detector with recorded/synthetic
  /// sensor sequences.
  @visibleForTesting
  final Stream<SensorSample>? debugSampleStream;

  CrashDetectionService({
    CrashConfig? config,
    DrivingContextService? drivingContext,
    this.logger,
    this.verboseLogging = kDebugMode,
    @visibleForTesting this.debugSampleStream,
  })  : config = config ?? const CrashConfig(),
        drivingContext = drivingContext ?? DrivingContextService();

  StreamSubscription<SensorSample>? _sub;
  Timer? _observationTimer;
  bool _isActive = false;

  CrashState _state = CrashState.normal;
  CrashEvidence _evidence = CrashEvidence.zero;
  double _speedAtCandidate = 0;
  double _minSpeedDuringObservation = double.infinity;
  double _peakLinearAccelDuringObservation = 0;
  double _peakGyroDuringObservation = 0;
  DateTime? _candidateAt;
  DateTime? _stillSince;
  Duration _longestStillStreak = Duration.zero;
  SensorSample? _candidateSample;
  bool _hadGpsEvidenceAtCandidate = false;

  /// Rolling buffer of raw (gravity-included) acceleration magnitude —
  /// only maintained while in [CrashState.normal] — used to look
  /// backwards for a free-fall period the instant an impact candidate
  /// fires. See [_precededByFreefall].
  final Queue<double> _preImpactAccelBuffer = Queue<double>();
  late final int _preImpactBufferSize =
      (config.freefallLookbackWindow.inMilliseconds / 20).round();

  bool get isActive => _isActive;
  CrashState get state => _state;
  CrashEvidence get evidence => _evidence;
  bool get crashDetected => _state == CrashState.verifyingImpact;
  Duration get confirmationCountdown => config.confirmationCountdown;

  void start() {
    if (_isActive) return;
    _isActive = true;

    if (debugSampleStream != null) {
      _sub = debugSampleStream!.listen(_onSample);
    } else {
      // DrivingContextService.start() is idempotent, so this is safe
      // even if something else also started the same instance.
      drivingContext.start();
      MotionSensorService.instance.acquire();
      _sub = MotionSensorService.instance.samples.listen(_onSample);
    }
    notifyListeners();
  }

  void stop() {
    _isActive = false;
    _sub?.cancel();
    _sub = null;
    _observationTimer?.cancel();
    _observationTimer = null;
    if (debugSampleStream == null) {
      MotionSensorService.instance.release();
      drivingContext.stop();
    }
    _setState(CrashState.normal);
    notifyListeners();
  }

  /// Called by the UI when the user taps "I'M OK".
  void cancel() {
    if (_state != CrashState.verifyingImpact) return;
    _log('[CANCELLED] user dismissed');
    _setState(CrashState.cancelled);
    _resetToNormal();
  }

  /// Called by the UI on countdown timeout, or an explicit "SEND SOS NOW".
  void confirm() {
    if (_state != CrashState.verifyingImpact) return;
    _log('[CRASH CONFIRMED]');
    _setState(CrashState.crashConfirmed);
  }

  void _onSample(SensorSample sample) {
    if (_state == CrashState.normal) {
      // Raw (gravity-included) magnitude is what reads near-zero during
      // free-fall — linearAccel has gravity already subtracted out, so it
      // can't show weightlessness the same way.
      _preImpactAccelBuffer.addLast(sample.accelMagnitude);
      if (_preImpactAccelBuffer.length > _preImpactBufferSize) {
        _preImpactAccelBuffer.removeFirst();
      }
      _checkForCandidate(sample);
      return;
    }
    // Already observing a candidate — keep updating the running peaks and
    // the stillness streak until the observation window closes.
    _peakLinearAccelDuringObservation =
        _peakLinearAccelDuringObservation < sample.linearAccelMagnitude
            ? sample.linearAccelMagnitude
            : _peakLinearAccelDuringObservation;
    _peakGyroDuringObservation = _peakGyroDuringObservation < sample.gyroMagnitude
        ? sample.gyroMagnitude
        : _peakGyroDuringObservation;
    if (drivingContext.lastSpeedMps < _minSpeedDuringObservation) {
      _minSpeedDuringObservation = drivingContext.lastSpeedMps;
    }

    final now = DateTime.now();
    if (sample.linearAccelMagnitude < config.postImpactStillnessThreshold) {
      _stillSince ??= now;
      final streak = now.difference(_stillSince!);
      if (streak > _longestStillStreak) _longestStillStreak = streak;
    } else {
      _stillSince = null;
    }
  }

  void _checkForCandidate(SensorSample sample) {
    if (sample.linearAccelMagnitude < config.impactCandidateThreshold) return;

    _candidateSample = sample;
    _candidateAt = DateTime.now();
    _speedAtCandidate = drivingContext.lastSpeedMps;
    _hadGpsEvidenceAtCandidate = drivingContext.hasRecentGpsSpeedEvidence &&
        _speedAtCandidate >= config.minimumMovingSpeedForVehicleEvidence;
    _minSpeedDuringObservation = _speedAtCandidate;
    _peakLinearAccelDuringObservation = sample.linearAccelMagnitude;
    _peakGyroDuringObservation = sample.gyroMagnitude;
    _stillSince = null;
    _longestStillStreak = Duration.zero;
    _precededByFreefall = _checkPrecededByFreefall();

    _setState(CrashState.possibleImpact);
    _log('[POSSIBLE IMPACT] linearAccel=${sample.linearAccelMagnitude.toStringAsFixed(1)} '
        'context=${drivingContext.context.name} speed=${_speedAtCandidate.toStringAsFixed(1)}m/s '
        'precededByFreefall=$_precededByFreefall');

    _observationTimer?.cancel();
    _observationTimer = Timer(config.postImpactWindow, _finishObservation);
  }

  bool _precededByFreefall = false;

  /// Scans the pre-impact raw-acceleration buffer for a sustained run
  /// below [CrashConfig.freefallThreshold] — the weightlessness signature
  /// of a falling object, which a vehicle collision never produces (the
  /// vehicle and phone are both under normal gravity right up until
  /// impact).
  bool _checkPrecededByFreefall() {
    final samples = _preImpactAccelBuffer.toList();
    if (samples.isEmpty) return false;
    const sampleInterval = Duration(milliseconds: 20);
    final requiredSamples =
        (config.minimumFreefallDuration.inMilliseconds / sampleInterval.inMilliseconds)
            .ceil();
    int consecutiveBelow = 0;
    for (final magnitude in samples) {
      if (magnitude < config.freefallThreshold) {
        consecutiveBelow++;
        if (consecutiveBelow >= requiredSamples) return true;
      } else {
        consecutiveBelow = 0;
      }
    }
    return false;
  }

  void _finishObservation() {
    if (_candidateAt == null) return;

    final evidence = _scoreEvidence();
    _evidence = evidence;
    notifyListeners();
    _log('[DETECTION]\n$evidence');
    _recordLogEvent(evidence);

    if (evidence.totalConfidence >= config.confirmationThreshold) {
      _setState(CrashState.verifyingImpact);
      _log('[VERIFYING] confidence=${evidence.totalConfidence.toStringAsFixed(2)} '
          '— starting ${config.confirmationCountdown.inSeconds}s user confirmation');
      // Stays in verifyingImpact until the UI calls confirm()/cancel().
    } else {
      if (evidence.totalConfidence >= config.possibleImpactThreshold) {
        _log('[NOT CONFIRMED] confidence '
            '${evidence.totalConfidence.toStringAsFixed(2)} below '
            '${config.confirmationThreshold} — back to normal');
      }
      _resetToNormal();
    }
  }

  CrashEvidence _scoreEvidence() {
    final hasVehicleContext = drivingContext.isVehicleOrRecentlyVehicle;

    // Acceleration score: how far the peak sits above the hard floor,
    // normalized against a generous span so a real high-speed impact
    // (well above the candidate gate) scores near 1.0. Hard-capped when
    // there's no vehicle context at all — a desk-tap can spike this
    // metric but can never buy its way past the cap alone.
    double accelScore = _peakLinearAccelDuringObservation <= config.impactHardFloor
        ? 0.0
        : ((_peakLinearAccelDuringObservation - config.impactHardFloor) / 40.0)
            .clamp(0.0, 1.0);
    if (!hasVehicleContext) {
      accelScore = accelScore.clamp(0.0, config.noVehicleContextScoreCap);
    }

    final gyroScore =
        (_peakGyroDuringObservation / config.gyroSignificantRate).clamp(0.0, 1.0);

    double speedDropScore = 0.0;
    double? speedDropMps;
    if (_speedAtCandidate > 1.0) {
      // Only meaningful if there was measurable speed to drop from.
      final drop = _speedAtCandidate - _minSpeedDuringObservation;
      speedDropMps = drop;
      speedDropScore = (drop / config.speedDropStrong).clamp(0.0, 1.0);
    }

    final drivingContextScore = drivingContext.context == DrivingContext.vehicle
        ? 1.0
        : (hasVehicleContext ? 0.6 : 0.0);

    final postImpactScore = (_longestStillStreak.inMilliseconds /
            config.postImpactStillnessRequired.inMilliseconds)
        .clamp(0.0, 1.0);

    // Independent vehicle-motion evidence: a REAL GPS speed reading (not
    // the vibration-only heuristic, not a stale/UNKNOWN context) at
    // candidate time, AND a measured post-impact speed drop that clears a
    // meaningful floor — not just the placeholder 0 that results when no
    // GPS speed was ever available. This is a hard requirement, not
    // another weighted vote: vehicle context, acceleration, gyro and
    // post-impact stillness can all be maxed out (exactly what a phone
    // drop produces) and still can't confirm a crash without this.
    final hasIndependentVehicleEvidence = _hadGpsEvidenceAtCandidate &&
        speedDropMps != null &&
        speedDropMps >= config.minimumRequiredSpeedDrop;

    final classification = _precededByFreefall && !hasIndependentVehicleEvidence
        ? 'PHONE_DROP'
        : (hasVehicleContext ? 'VEHICLE_EVENT' : 'UNCLASSIFIED');

    var total = accelScore * config.weightAcceleration +
        gyroScore * config.weightGyro +
        speedDropScore * config.weightSpeedDrop +
        drivingContextScore * config.weightDrivingContext +
        postImpactScore * config.weightPostImpactStillness;

    if (!hasIndependentVehicleEvidence) {
      total = total.clamp(0.0, config.noIndependentEvidenceScoreCap);
    }

    return CrashEvidence(
      accelerationScore: accelScore,
      gyroScore: gyroScore,
      speedDropScore: speedDropScore,
      drivingContextScore: drivingContextScore,
      postImpactScore: postImpactScore,
      totalConfidence: total,
      peakLinearAccel: _peakLinearAccelDuringObservation,
      peakGyroRate: _peakGyroDuringObservation,
      speedDropMps: speedDropMps,
      drivingContext: drivingContext.context.name,
      precededByFreefall: _precededByFreefall,
      hasIndependentVehicleEvidence: hasIndependentVehicleEvidence,
      classification: classification,
    );
  }

  void _resetToNormal() {
    _observationTimer?.cancel();
    _observationTimer = null;
    _candidateAt = null;
    _setState(CrashState.normal);
  }

  void _setState(CrashState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  void _log(String message) {
    if (!verboseLogging) return;
    debugPrint(message);
  }

  void _recordLogEvent(CrashEvidence evidence) {
    if (logger == null || !logger!.enabled) return;
    final sample = _candidateSample;
    if (sample == null) return;
    logger!.record(DetectionEvent(
      timestamp: DateTime.now(),
      detector: 'crash',
      accelX: sample.accelX,
      accelY: sample.accelY,
      accelZ: sample.accelZ,
      gyroX: sample.gyroX,
      gyroY: sample.gyroY,
      gyroZ: sample.gyroZ,
      linearAccelMagnitude: evidence.peakLinearAccel,
      gpsSpeedMps: drivingContext.lastSpeedMps,
      orientation: 'unknown',
      activityState: evidence.drivingContext,
      detectorState: _state.name,
      confidence: evidence.totalConfidence,
      classification: evidence.classification,
    ));
  }
}
