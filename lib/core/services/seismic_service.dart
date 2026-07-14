import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';

class SeismicService extends ChangeNotifier {
  // STA/LTA algorithm parameters
  static const int _shortWindow = 20; // ~1 second of samples
  static const int _longWindow = 200; // ~10 seconds of samples
  static const double _triggerRatio = 4.0; // STA/LTA ratio to trigger alert
  static const double _stationaryThreshold = 0.3; // m/s² — phone must be still

  StreamSubscription<UserAccelerometerEvent>? _sub;
  final Queue<double> _samples = Queue<double>();

  bool _isActive = false;
  bool _quakeDetected = false;
  bool _isStationary = false;
  DateTime? _lastAlertTime;

  bool get isActive => _isActive;
  bool get quakeDetected => _quakeDetected;
  bool get isStationary => _isStationary;

  void start() {
    if (_isActive) return;
    _isActive = true;
    // UserAccelerometer excludes gravity — pure motion only
    _sub = userAccelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval, // ~20ms = 50Hz
    ).listen(_onSample);
    notifyListeners();
  }

  void stop() {
    _isActive = false;
    _quakeDetected = false;
    _sub?.cancel();
    _sub = null;
    _samples.clear();
    notifyListeners();
  }

  void resetAlert() {
    _quakeDetected = false;
    notifyListeners();
  }

  void _onSample(UserAccelerometerEvent event) {
    final magnitude = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    _samples.addLast(magnitude);
    if (_samples.length > _longWindow) _samples.removeFirst();
    if (_samples.length < _longWindow) return; // need full buffer first

    final list = _samples.toList();

    // Long-term average — the background noise level
    final lta = list.reduce((a, b) => a + b) / list.length;

    // Phone must be essentially still (on table/charging) to monitor
    _isStationary = lta < _stationaryThreshold;
    if (!_isStationary) return;

    // Short-term average — the last ~1 second
    final recent = list.sublist(list.length - _shortWindow);
    final sta = recent.reduce((a, b) => a + b) / recent.length;

    // Avoid divide-by-zero on perfectly still phones
    final ratio = sta / max(lta, 0.02);

    if (ratio > _triggerRatio && !_quakeDetected) {
      // Don't re-alert within 2 minutes
      if (_lastAlertTime != null &&
          DateTime.now().difference(_lastAlertTime!).inSeconds < 120) {
        return;
      }
      _lastAlertTime = DateTime.now();
      _quakeDetected = true;
      notifyListeners();
    }
  }
}