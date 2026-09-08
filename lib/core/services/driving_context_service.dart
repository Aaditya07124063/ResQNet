import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'motion_sensor_service.dart';
import '../models/sensor_sample.dart';

enum DrivingContext { unknown, stationary, walking, vehicle }

/// Estimates whether the phone is currently traveling in a vehicle, using
/// only GPS speed + the accelerometer's own vibration pattern — no
/// activity-recognition plugin, no extra permission.
///
/// The crash detector only takes a vibration seriously as a possible
/// impact when this says [DrivingContext.vehicle] (or a recent-enough
/// vehicle context that a sudden stop could plausibly be a crash) — a
/// phone shaken on a desk never gets that context, so it can't pass the
/// crash pipeline no matter how hard it's shaken.
///
/// Hysteresis: entering "vehicle" requires sustained evidence (so a
/// single fast GPS fix or one rough patch of road doesn't flip the
/// state), and leaving it requires sustained absence of evidence — this
/// stops the classic noisy-sensor VEHICLE→NOT_VEHICLE→VEHICLE flutter.
class DrivingContextService extends ChangeNotifier {
  // Speed thresholds (m/s). ~8 m/s ≈ 29 km/h — comfortably above walking
  ///running speed (even sprinting rarely sustains >6 m/s) but low enough
  // to catch city-street driving, not just highways.
  static const double _vehicleEnterSpeed = 8.0;
  static const double _vehicleExitSpeed = 2.5;
  static const Duration _enterHoldTime = Duration(seconds: 5);
  static const Duration _exitHoldTime = Duration(seconds: 5);

  // How long a vehicle context is still "recent" after we lose GPS/speed
  // evidence — a crash can knock a phone free of a mount or a sudden stop
  // can drop measured speed to ~0 right when it matters most, so recency
  // (not just the instantaneous state) is what the crash detector checks.
  static const Duration _recentVehicleWindow = Duration(seconds: 8);

  /// How recently a genuine GPS speed reading (see [_onPosition]'s own
  /// accuracy filter) above [_gpsEvidenceSpeedFloor] must have arrived for
  /// [hasRecentGpsSpeedEvidence] to be true. Deliberately shorter than
  /// [_recentVehicleWindow] — that window is for the *context label*
  /// (forgiving, UI-facing); this one gates whether the crash detector is
  /// allowed to treat the phone as having independently-verified vehicle
  /// motion, so it stays tight to the actual candidate/observation window.
  static const Duration _gpsEvidenceRecency = Duration(seconds: 10);
  static const double _gpsEvidenceSpeedFloor = 3.0;

  StreamSubscription<Position>? _positionSub;
  StreamSubscription<SensorSample>? _motionSub;
  final Queue<double> _accelWindow = Queue<double>();
  static const int _accelWindowSize = 100; // ~2s at 50Hz

  DrivingContext _context = DrivingContext.unknown;
  double _lastSpeed = 0;
  DateTime? _aboveEnterSince;
  DateTime? _belowExitSince;
  DateTime? _lastVehicleAt;
  DateTime? _lastGpsSpeedEvidenceAt;
  bool _active = false;

  DrivingContext get context => _context;
  double get lastSpeedMps => _lastSpeed;
  bool get isVehicleOrRecentlyVehicle =>
      _context == DrivingContext.vehicle ||
      (_lastVehicleAt != null &&
          DateTime.now().difference(_lastVehicleAt!) < _recentVehicleWindow);

  /// True only when a REAL GPS fix (not the accelerometer-vibration
  /// heuristic — see [_hasVehicleVibrationPattern]) recently reported
  /// speed above [_gpsEvidenceSpeedFloor]. This is deliberately a
  /// narrower, stricter signal than [context]/[isVehicleOrRecentlyVehicle]:
  /// those exist to drive a forgiving UI label, but the crash detector's
  /// "independent vehicle evidence" gate must not be satisfiable by
  /// vibration pattern alone (a bus, train, or a false pattern match while
  /// walking would otherwise be enough) or by an UNKNOWN/stale context.
  bool get hasRecentGpsSpeedEvidence =>
      _lastGpsSpeedEvidenceAt != null &&
      DateTime.now().difference(_lastGpsSpeedEvidenceAt!) < _gpsEvidenceRecency;

  /// Test-only: directly set the context/speed this service reports,
  /// without touching real GPS/accelerometer streams — lets
  /// CrashDetectionService's tests simulate "definitely driving" or
  /// "definitely sitting on a desk" without a real device. Also marks
  /// genuine GPS evidence as present when speedMps clears the evidence
  /// floor, so tests can simulate a real (not vibration-only) vehicle
  /// reading, and can call this again mid-test with a lower speed to
  /// simulate a real deceleration/speed-drop event.
  @visibleForTesting
  void debugSetContext(DrivingContext context, {double speedMps = 0}) {
    _context = context;
    _lastSpeed = speedMps;
    if (context == DrivingContext.vehicle) _lastVehicleAt = DateTime.now();
    if (speedMps >= _gpsEvidenceSpeedFloor) {
      _lastGpsSpeedEvidenceAt = DateTime.now();
    }
    notifyListeners();
  }

  void start() {
    if (_active) return;
    _active = true;

    MotionSensorService.instance.acquire();
    _motionSub = MotionSensorService.instance.samples.listen(_onMotion);

    // Medium accuracy + a modest distance filter — enough to track speed
    // trends for driving-context without polling GPS at high frequency.
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 5,
      ),
    ).listen(_onPosition, onError: (_) {});
  }

  void stop() {
    if (!_active) return;
    _active = false;
    _motionSub?.cancel();
    _motionSub = null;
    MotionSensorService.instance.release();
    _positionSub?.cancel();
    _positionSub = null;
    _accelWindow.clear();
    _context = DrivingContext.unknown;
    _aboveEnterSince = null;
    _belowExitSince = null;
    _lastGpsSpeedEvidenceAt = null;
  }

  void _onPosition(Position position) {
    // GPS speed is unreliable at low speed/poor fix — ignore obviously
    // noisy readings rather than let them drive state changes.
    if (position.speedAccuracy > 0 && position.speedAccuracy > 5) return;
    _lastSpeed = position.speed < 0 ? 0 : position.speed;
    if (_lastSpeed >= _gpsEvidenceSpeedFloor) {
      _lastGpsSpeedEvidenceAt = DateTime.now();
    }
    _evaluate();
  }

  void _onMotion(SensorSample sample) {
    _accelWindow.addLast(sample.linearAccelMagnitude);
    if (_accelWindow.length > _accelWindowSize) _accelWindow.removeFirst();
  }

  /// A car's engine/road vibration shows up as small, fairly steady
  /// variance in linear acceleration — enough to distinguish "sitting on
  /// a desk" (near-zero variance) from "moving in a vehicle", without
  /// being anywhere near crash-impact magnitude.
  bool get _hasVehicleVibrationPattern {
    if (_accelWindow.length < _accelWindowSize) return false;
    final mean = _accelWindow.reduce((a, b) => a + b) / _accelWindow.length;
    final variance = _accelWindow
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        _accelWindow.length;
    final stdDev = sqrt(variance);
    return stdDev > 0.15 && stdDev < 3.0;
  }

  void _evaluate() {
    final now = DateTime.now();
    final speedSaysVehicle = _lastSpeed >= _vehicleEnterSpeed;
    final speedSaysNotVehicle = _lastSpeed < _vehicleExitSpeed;

    if (_context != DrivingContext.vehicle) {
      if (speedSaysVehicle || _hasVehicleVibrationPattern) {
        _aboveEnterSince ??= now;
        if (now.difference(_aboveEnterSince!) >= _enterHoldTime) {
          _setContext(DrivingContext.vehicle);
        }
      } else {
        _aboveEnterSince = null;
        _setContext(speedSaysNotVehicle
            ? (_lastSpeed > 0.5 ? DrivingContext.walking : DrivingContext.stationary)
            : DrivingContext.unknown);
      }
    } else {
      if (speedSaysNotVehicle && !_hasVehicleVibrationPattern) {
        _belowExitSince ??= now;
        if (now.difference(_belowExitSince!) >= _exitHoldTime) {
          _setContext(DrivingContext.stationary);
        }
      } else {
        _belowExitSince = null;
      }
    }
  }

  void _setContext(DrivingContext next) {
    if (next == _context) return;
    _context = next;
    if (next == DrivingContext.vehicle) {
      _lastVehicleAt = DateTime.now();
      _aboveEnterSince = null;
    } else {
      _belowExitSince = null;
    }
    notifyListeners();
  }
}
