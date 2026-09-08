import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/detection_event.dart';
import '../models/earthquake_config.dart';
import '../models/earthquake_evidence.dart';
import '../models/sensor_sample.dart';
import 'detection_logging_service.dart';
import 'earthquake_correlation_service.dart';
import 'motion_sensor_service.dart';

/// Earthquake detector — separate thresholds and separate signal from
/// crash detection (see EarthquakeConfig vs CrashConfig).
///
/// The core STA/LTA algorithm here was already sound before this rewrite
/// — it's kept, not replaced. What's new: a layer-1 amplitude gate (skips
/// STA/LTA math entirely for ordinary background noise, and avoids the
/// ratio going unstable when both averages are near-zero), a minimum
/// *sustained* duration above the trigger ratio (a real quake shakes for
/// seconds; a knock is over in under a second), and an oscillation-count
/// check (a quake moves back and forth repeatedly; a tap is one impulse).
/// A single short spike — however hard — cannot satisfy both of the new
/// gates no matter how the STA/LTA ratio behaves.
///
/// Pipeline: shared accelerometer (MotionSensorService, gravity already
/// removed) → amplitude gate → STA/LTA → sustained-duration + oscillation
/// checks → confidence → state machine → (optional) multi-device
/// correlation via Firestore → user confirmation → SOS, same as crash.
class SeismicService extends ChangeNotifier {
  final EarthquakeConfig config;
  final EarthquakeCorrelationService correlation;
  final DetectionLoggingService? logger;
  final bool verboseLogging;

  /// Test-only: see CrashDetectionService.debugSampleStream — same idea,
  /// same reason (sensors_plus needs a real platform channel).
  @visibleForTesting
  final Stream<SensorSample>? debugSampleStream;

  SeismicService({
    EarthquakeConfig? config,
    EarthquakeCorrelationService? correlation,
    this.logger,
    this.verboseLogging = kDebugMode,
    @visibleForTesting this.debugSampleStream,
  })  : config = config ?? const EarthquakeConfig(),
        correlation = correlation ?? EarthquakeCorrelationService();

  StreamSubscription<SensorSample>? _sub;
  final Queue<double> _longWindow = Queue<double>();
  final Queue<double> _shortWindow = Queue<double>();
  SensorSample? _lastSample;
  DateTime? _lastSampleTime;

  bool _isActive = false;
  bool _isStationary = false;
  EarthquakeState _state = EarthquakeState.normal;
  EarthquakeEvidence _evidence = EarthquakeEvidence.zero;
  DateTime? _lastAlertTime;
  DateTime? _sustainedSince;
  double _peakRatioDuringCandidate = 0;
  int _peakOscillationsDuringCandidate = 0;

  /// Peak gyroscope magnitude (rad/s) seen while the current candidate has
  /// been sustained — a deliberate pickup/rotation rotates the phone far
  /// more than ground shaking ever rotates a resting one.
  double _peakGyroDuringCandidate = 0;

  /// Running integral of |linearAccel| over time (seismology's CAV) since
  /// the candidate began — accumulates steadily for genuine sustained
  /// shaking, stays small for a brief pickup even if that pickup's
  /// instantaneous ratio/oscillation count briefly look quake-like.
  double _cavDuringCandidate = 0;

  bool get isActive => _isActive;
  bool get quakeDetected => _state == EarthquakeState.verifying;
  bool get isStationary => _isStationary;
  EarthquakeState get state => _state;
  EarthquakeEvidence get evidence => _evidence;
  Duration get confirmationCountdown => config.confirmationCountdown;

  void start() {
    if (_isActive) return;
    _isActive = true;
    if (debugSampleStream != null) {
      _sub = debugSampleStream!.listen(_onSample);
    } else {
      MotionSensorService.instance.acquire();
      _sub = MotionSensorService.instance.samples.listen(_onSample);
    }
    notifyListeners();
  }

  void stop() {
    _isActive = false;
    _state = EarthquakeState.normal;
    _sub?.cancel();
    _sub = null;
    if (debugSampleStream == null) MotionSensorService.instance.release();
    _longWindow.clear();
    _shortWindow.clear();
    _sustainedSince = null;
    _lastSampleTime = null;
    _peakGyroDuringCandidate = 0;
    _cavDuringCandidate = 0;
    notifyListeners();
  }

  void resetAlert() {
    _state = EarthquakeState.normal;
    _sustainedSince = null;
    notifyListeners();
  }

  /// Called by the UI when the user taps "I'M SAFE" during confirmation.
  void cancel() {
    if (_state != EarthquakeState.verifying) return;
    _log('[CANCELLED] user dismissed');
    _state = EarthquakeState.cancelled;
    _sustainedSince = null;
    notifyListeners();
  }

  /// Called by the UI on countdown timeout, or an explicit confirm action.
  void confirm() {
    if (_state != EarthquakeState.verifying) return;
    _log('[EARTHQUAKE CONFIRMED]');
    _state = EarthquakeState.confirmed;
    notifyListeners();
  }

  void _onSample(SensorSample sample) {
    final now = DateTime.now();
    final dt = _lastSampleTime == null
        ? 1 / config.sampleRateHz
        : now.difference(_lastSampleTime!).inMicroseconds / 1e6;
    _lastSampleTime = now;
    _lastSample = sample;
    final magnitude = sample.linearAccelMagnitude;

    _longWindow.addLast(magnitude);
    if (_longWindow.length > config.longWindowSamples) _longWindow.removeFirst();
    _shortWindow.addLast(magnitude);
    if (_shortWindow.length > config.shortWindowSamples) _shortWindow.removeFirst();

    if (_longWindow.length < config.longWindowSamples) return;

    final lta = _longWindow.reduce((a, b) => a + b) / _longWindow.length;
    _isStationary = lta < config.stationaryThreshold;
    if (!_isStationary) {
      _sustainedSince = null;
      return;
    }
    if (_shortWindow.length < config.shortWindowSamples) return;

    final peakInShortWindow = _shortWindow.reduce(max);
    // Layer-1 gate: below this, don't trust the ratio at all — with both
    // STA and LTA near-zero, the ratio is just noise dividing noise.
    if (peakInShortWindow < config.amplitudeGate) {
      _sustainedSince = null;
      return;
    }

    final sta = _shortWindow.reduce((a, b) => a + b) / _shortWindow.length;
    final ratio = sta / max(lta, 0.02);
    final oscillations = _countOscillations(_shortWindow);

    if (ratio > config.triggerRatio) {
      _sustainedSince ??= now;
      _peakRatioDuringCandidate = max(_peakRatioDuringCandidate, ratio);
      _peakOscillationsDuringCandidate =
          max(_peakOscillationsDuringCandidate, oscillations);
      _peakGyroDuringCandidate =
          max(_peakGyroDuringCandidate, sample.gyroMagnitude);
      // CAV: the running integral of |acceleration| over time — genuine
      // shaking accumulates this steadily across the whole sustained
      // period, unlike a brief pickup.
      _cavDuringCandidate += magnitude * dt;

      final sustainedDuration = now.difference(_sustainedSince!);
      if (sustainedDuration >= config.minimumSustainedDuration) {
        _evaluateCandidate(sustainedDuration);
      }
    } else {
      _sustainedSince = null;
      _peakRatioDuringCandidate = 0;
      _peakOscillationsDuringCandidate = 0;
      _peakGyroDuringCandidate = 0;
      _cavDuringCandidate = 0;
    }
  }

  /// Counts direction reversals of (value - windowMean) — a rough but
  /// cheap way to tell "shook back and forth repeatedly" (many reversals)
  /// from "one hard impulse" (at most one or two).
  int _countOscillations(Queue<double> window) {
    final values = window.toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    int reversals = 0;
    bool? wasAbove;
    for (final v in values) {
      final above = v > mean;
      if (wasAbove != null && above != wasAbove) reversals++;
      wasAbove = above;
    }
    return reversals;
  }

  /// Interquartile range of the short window's magnitude samples — the
  /// spread of the middle 50% of readings. A real seismic waveform keeps
  /// most of the window actively moving (wide spread); a brief pickup
  /// impulse is mostly flat baseline with one narrow excursion (narrow
  /// spread relative to its peak).
  double _computeIqr(Queue<double> window) {
    final sorted = window.toList()..sort();
    final q1 = sorted[(sorted.length * 0.25).floor()];
    final q3 = sorted[(sorted.length * 0.75).floor()];
    return q3 - q1;
  }

  void _evaluateCandidate(Duration sustainedDuration) {
    if (_state == EarthquakeState.verifying ||
        _state == EarthquakeState.confirmed) {
      return;
    }
    if (_lastAlertTime != null &&
        DateTime.now().difference(_lastAlertTime!) < config.reAlertCooldown) {
      return;
    }

    final ratioScore =
        (_peakRatioDuringCandidate / (config.triggerRatio * 2)).clamp(0.0, 1.0);
    final durationScore = (sustainedDuration.inMilliseconds /
            (config.minimumSustainedDuration.inMilliseconds * 2))
        .clamp(0.0, 1.0);
    final oscillationScore =
        (_peakOscillationsDuringCandidate / (config.minimumOscillations * 2))
            .clamp(0.0, 1.0);
    final iqr = _computeIqr(_shortWindow);
    // Normalized against a span comparable to the amplitude gate — a
    // window dominated by one spike has most values near the median (low
    // IQR); genuine shaking has most of the window actively displaced.
    final iqrScore = (iqr / (config.amplitudeGate * 3)).clamp(0.0, 1.0);
    final cavScore =
        (_cavDuringCandidate / (config.minimumCav * 2)).clamp(0.0, 1.0);

    // Gyro/orientation gate — the direct fix for phone-pickup false
    // positives. A resting phone genuinely shaken by ground motion barely
    // rotates; a hand picking it up or turning it over rotates it hard.
    final peakGyro = _peakGyroDuringCandidate;
    final rejectedByGyro = peakGyro >= config.gyroHardRejectThreshold;
    final gyroSuppressionFactor = rejectedByGyro
        ? 0.0
        : (1.0 -
                ((peakGyro - config.gyroSuppressionThreshold) /
                        (config.gyroHardRejectThreshold -
                            config.gyroSuppressionThreshold))
                    .clamp(0.0, 1.0))
            .clamp(0.0, 1.0);

    final weightedTotal = ratioScore * config.weightStaLtaRatio +
        durationScore * config.weightDuration +
        oscillationScore * config.weightOscillation +
        iqrScore * config.weightIqr +
        cavScore * config.weightCav;
    // Gyro suppression is a MULTIPLIER, not another weighted vote — strong
    // manual rotation crushes confidence regardless of how oscillatory or
    // sustained the accelerometer signal looks on its own.
    final total = weightedTotal * gyroSuppressionFactor;

    final evidence = EarthquakeEvidence(
      ratioScore: ratioScore,
      durationScore: durationScore,
      oscillationScore: oscillationScore,
      totalConfidence: total,
      staLtaRatio: _peakRatioDuringCandidate,
      sustainedDuration: sustainedDuration,
      oscillationCount: _peakOscillationsDuringCandidate,
      iqrScore: iqrScore,
      cavScore: cavScore,
      cumulativeAbsoluteVelocity: _cavDuringCandidate,
      peakGyroMagnitude: peakGyro,
      gyroSuppressionFactor: gyroSuppressionFactor,
      rejectedByGyro: rejectedByGyro,
    );
    _evidence = evidence;
    notifyListeners();
    _log('[DETECTION]\n$evidence');
    _recordLogEvent(evidence);

    // Hard gates — none of these can be bought back by the weighted score,
    // matching "oscillation count alone must not be sufficient" and "a
    // single acceleration spike must never be sufficient": sustained
    // oscillatory motion (existing gate), sustained accumulated energy
    // (CAV, new), and absence of strong manual rotation (gyro, new) are
    // all independently required.
    if (_peakOscillationsDuringCandidate < config.minimumOscillations) return;
    if (_cavDuringCandidate < config.minimumCav) return;
    if (rejectedByGyro) return;

    if (total < config.candidateThreshold) return;

    _state = EarthquakeState.candidate;
    _log('[POSSIBLE EARTHQUAKE] confidence=${total.toStringAsFixed(2)}');
    correlation.reportCandidate(evidence);

    if (total >= config.confirmationThreshold) {
      _lastAlertTime = DateTime.now();
      _state = EarthquakeState.verifying;
      _log('[VERIFYING] starting ${config.confirmationCountdown.inSeconds}s '
          'user confirmation');
    }
    notifyListeners();
  }

  void _log(String message) {
    if (!verboseLogging) return;
    debugPrint(message);
  }

  void _recordLogEvent(EarthquakeEvidence evidence) {
    if (logger == null || !logger!.enabled) return;
    final sample = _lastSample;
    if (sample == null) return;
    logger!.record(DetectionEvent(
      timestamp: DateTime.now(),
      detector: 'earthquake',
      accelX: sample.accelX,
      accelY: sample.accelY,
      accelZ: sample.accelZ,
      gyroX: sample.gyroX,
      gyroY: sample.gyroY,
      gyroZ: sample.gyroZ,
      linearAccelMagnitude: sample.linearAccelMagnitude,
      orientation: 'peakGyro=${evidence.peakGyroMagnitude.toStringAsFixed(2)}rad/s',
      activityState: _isStationary ? 'STATIONARY' : 'MOVING',
      detectorState: _state.name,
      confidence: evidence.totalConfidence,
      classification: evidence.rejectedByGyro
          ? 'REJECTED_GYRO_MOTION'
          : (_peakOscillationsDuringCandidate < config.minimumOscillations
              ? 'REJECTED_NOT_OSCILLATORY'
              : (_cavDuringCandidate < config.minimumCav
                  ? 'REJECTED_INSUFFICIENT_CAV'
                  : 'SEISMIC_CANDIDATE')),
    ));
  }
}
