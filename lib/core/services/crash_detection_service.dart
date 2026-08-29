import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

class CrashDetectionService extends ChangeNotifier {
  // 40 m/s² ≈ 4g — typical vehicle crash threshold
  static const double _crashThreshold = 40.0;
  static const double _stillnessThreshold = 12.0;
  // Must stay still for this long after impact — a single low sample can
  // occur mid-shake by chance, but sustained stillness can't.
  static const Duration _requiredStillness = Duration(milliseconds: 400);

  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _isActive = false;
  bool _crashDetected = false;
  DateTime? _highGTimestamp;
  DateTime? _stillSince;
  double _speedAtImpact = 0.0;

  bool get isActive => _isActive;
  bool get crashDetected => _crashDetected;
  double get speedAtImpact => _speedAtImpact;

  void start() {
    if (_isActive) return;
    _isActive = true;
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(_onAccelerometer);
    notifyListeners();
  }

  void stop() {
    _isActive = false;
    _crashDetected = false;
    _accelSub?.cancel();
    _accelSub = null;
    notifyListeners();
  }

  void resetCrash() {
    _crashDetected = false;
    _highGTimestamp = null;
    _stillSince = null;
    notifyListeners();
  }

  void _onAccelerometer(AccelerometerEvent event) {
    if (_crashDetected) return;

    final magnitude = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    if (magnitude > _crashThreshold && _highGTimestamp == null) {
      _highGTimestamp = DateTime.now();
      _stillSince = null;
      _captureSpeed();
      return;
    }

    if (_highGTimestamp == null) return;

    final elapsed = DateTime.now().difference(_highGTimestamp!);
    if (elapsed.inSeconds > 5) {
      _highGTimestamp = null;
      _stillSince = null;
      return;
    }

    if (magnitude < _stillnessThreshold) {
      _stillSince ??= DateTime.now();
      if (DateTime.now().difference(_stillSince!) >= _requiredStillness) {
        _crashDetected = true;
        notifyListeners();
      }
    } else {
      // Still moving above the stillness threshold — e.g. continued
      // shaking — so the "settled after impact" pattern hasn't happened.
      _stillSince = null;
    }
  }

  Future<void> _captureSpeed() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos != null && pos.speed > 0) {
        _speedAtImpact = pos.speed * 3.6; // m/s → km/h
      }
    } catch (_) {
      _speedAtImpact = 0.0;
    }
  }
}