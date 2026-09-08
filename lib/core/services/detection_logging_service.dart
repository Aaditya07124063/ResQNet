import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/detection_event.dart';

/// Developer/testing mode: records every detector evaluation (not raw
/// 50Hz samples — that would be enormous — one row per evaluated
/// candidate/window) so real-world false positives and true positives
/// can be reviewed and exported, and eventually used to validate or
/// train a real classifier. Off by default; enabling it has no effect on
/// detection logic itself, only on what gets recorded.
class DetectionLoggingService extends ChangeNotifier {
  static const _storageKey = 'detection_log_enabled';
  static const _maxBufferedEvents = 2000;

  bool _enabled = false;
  final List<DetectionEvent> _buffer = [];

  bool get enabled => _enabled;
  List<DetectionEvent> get events => List.unmodifiable(_buffer);
  int get eventCount => _buffer.length;

  Future<void> loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_storageKey) ?? false;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storageKey, value);
  }

  void record(DetectionEvent event) {
    if (!_enabled) return;
    _buffer.add(event);
    if (_buffer.length > _maxBufferedEvents) {
      _buffer.removeAt(0);
    }
    notifyListeners();
  }

  void clear() {
    _buffer.clear();
    notifyListeners();
  }

  /// Human-labels the most recent event — used after a test run, e.g.
  /// "this was a table tap, not a crash", so the export is useful for
  /// validating detector behavior against ground truth.
  void labelLastEvent(String label) {
    if (_buffer.isEmpty) return;
    final last = _buffer.removeLast();
    _buffer.add(DetectionEvent(
      timestamp: last.timestamp,
      detector: last.detector,
      accelX: last.accelX,
      accelY: last.accelY,
      accelZ: last.accelZ,
      gyroX: last.gyroX,
      gyroY: last.gyroY,
      gyroZ: last.gyroZ,
      linearAccelMagnitude: last.linearAccelMagnitude,
      gpsSpeedMps: last.gpsSpeedMps,
      gpsLatitude: last.gpsLatitude,
      gpsLongitude: last.gpsLongitude,
      orientation: last.orientation,
      activityState: last.activityState,
      detectorState: last.detectorState,
      confidence: last.confidence,
      eventLabel: label,
      classification: last.classification,
    ));
    notifyListeners();
  }

  String exportAsJson() =>
      jsonEncode(_buffer.map((e) => e.toJson()).toList());

  String exportAsCsv() {
    const header = 'timestamp,detector,accelX,accelY,accelZ,gyroX,gyroY,gyroZ,'
        'linearAccelMagnitude,gpsSpeedMps,gpsLatitude,gpsLongitude,'
        'orientation,activityState,detectorState,confidence,eventLabel,classification';
    final rows = _buffer.map((e) {
      final j = e.toJson();
      return [
        j['timestamp'],
        j['detector'],
        j['accelX'],
        j['accelY'],
        j['accelZ'],
        j['gyroX'],
        j['gyroY'],
        j['gyroZ'],
        j['linearAccelMagnitude'],
        j['gpsSpeedMps'],
        j['gpsLatitude'],
        j['gpsLongitude'],
        j['orientation'],
        j['activityState'],
        j['detectorState'],
        j['confidence'],
        j['eventLabel'],
        j['classification'],
      ].join(',');
    });
    return ([header, ...rows]).join('\n');
  }
}
