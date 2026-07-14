import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocationLogService extends ChangeNotifier {
  static const _key = 'location_trail';
  static const _maxEntries = 288; // 24 hours at 5-minute intervals

  Timer? _timer;
  List<Map<String, dynamic>> _trail = [];

  List<Map<String, dynamic>> get trail => List.unmodifiable(_trail.reversed);
  bool get isActive => _timer != null;

  Future<void> start() async {
    if (_timer != null) return;
    await _load();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _log());
    _log(); // log immediately on start
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      _trail = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    }
  }

  Future<void> _log() async {
    try {
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      ).timeout(const Duration(seconds: 10));

      _trail.add({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'time': DateTime.now().toIso8601String(),
      });
      if (_trail.length > _maxEntries) {
        _trail = _trail.sublist(_trail.length - _maxEntries);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_trail));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> clear() async {
    _trail.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    notifyListeners();
  }
}