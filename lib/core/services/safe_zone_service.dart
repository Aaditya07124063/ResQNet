import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SafeZone {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String type; // home, hospital, school, shelter, high_ground

  SafeZone({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'type': type,
      };

  factory SafeZone.fromJson(Map<String, dynamic> json) => SafeZone(
        id: json['id'],
        name: json['name'],
        latitude: json['latitude'],
        longitude: json['longitude'],
        type: json['type'] ?? 'shelter',
      );

  IconData get icon {
    switch (type) {
      case 'home':
        return Icons.home;
      case 'hospital':
        return Icons.local_hospital;
      case 'school':
        return Icons.school;
      case 'high_ground':
        return Icons.terrain;
      default:
        return Icons.night_shelter;
    }
  }
}

class SafeZoneService extends ChangeNotifier {
  static const _storageKey = 'safe_zones';
  List<SafeZone> _zones = [];

  List<SafeZone> get zones => List.unmodifiable(_zones);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      _zones = list.map((e) => SafeZone.fromJson(e)).toList();
      notifyListeners();
    }
  }

  Future<void> addZone(SafeZone zone) async {
    _zones.add(zone);
    notifyListeners();
    await _persist();
  }

  Future<void> removeZone(String id) async {
    _zones.removeWhere((z) => z.id == id);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(_zones.map((z) => z.toJson()).toList()),
    );
  }

  /// Distance in km between two points (Haversine)
  static double distanceKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _rad(b.latitude - a.latitude);
    final dLng = _rad(b.longitude - a.longitude);
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(a.latitude)) * cos(_rad(b.latitude)) *
            sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  static double _rad(double deg) => deg * pi / 180;

  /// Nearest safe zone to the given position, or null if none saved
  SafeZone? nearestZone(LatLng from) {
    if (_zones.isEmpty) return null;
    SafeZone? best;
    double bestDist = double.infinity;
    for (final z in _zones) {
      final d = distanceKm(from, LatLng(z.latitude, z.longitude));
      if (d < bestDist) {
        bestDist = d;
        best = z;
      }
    }
    return best;
  }
}