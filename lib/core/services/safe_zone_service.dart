import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';

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

/// A path (not just a point) that is safe to travel — e.g. an evacuation
/// route a government agency has confirmed is clear of a flood or
/// landslide. Broadcasts over the mesh the same way a [SafeZone] or hazard
/// does, so it reaches phones with no internet.
class SafeRoute {
  final String id;
  final String name;
  final String description;
  final String safeFrom; // flood, landslide, fire, general, etc.
  final List<LatLng> points;
  final String source; // 'official' or a peer's name
  final DateTime timestamp;

  SafeRoute({
    required this.id,
    required this.name,
    required this.description,
    required this.safeFrom,
    required this.points,
    required this.source,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'safeFrom': safeFrom,
        'points': points.map((p) => [p.latitude, p.longitude]).toList(),
        'source': source,
        'timestamp': timestamp.toIso8601String(),
      };

  factory SafeRoute.fromJson(Map<String, dynamic> json) => SafeRoute(
        id: json['id'],
        name: json['name'] ?? 'Safe route',
        description: json['description'] ?? '',
        safeFrom: json['safeFrom'] ?? 'general',
        points: (json['points'] as List)
            .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
        source: json['source'] ?? 'Unknown',
        timestamp: DateTime.parse(json['timestamp']),
      );

  bool get isExpired => DateTime.now().difference(timestamp).inHours >= 48;
}

class SafeZoneService extends ChangeNotifier {
  static const _zonesStorageKey = 'safe_zones';
  static const _routesStorageKey = 'safe_routes';
  static const zonePrefix = 'SAFEZONE|';
  static const routePrefix = 'SAFEROUTE|';

  List<SafeZone> _zones = [];
  final Map<String, SafeRoute> _routes = {};

  List<SafeZone> get zones => List.unmodifiable(_zones);
  List<SafeRoute> get routes =>
      _routes.values.where((r) => !r.isExpired).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawZones = prefs.getString(_zonesStorageKey);
    if (rawZones != null) {
      final list = jsonDecode(rawZones) as List;
      _zones = list.map((e) => SafeZone.fromJson(e)).toList();
    }
    final rawRoutes = prefs.getString(_routesStorageKey);
    if (rawRoutes != null) {
      final list = jsonDecode(rawRoutes) as List;
      for (final e in list) {
        final r = SafeRoute.fromJson(e);
        if (!r.isExpired) _routes[r.id] = r;
      }
    }
    notifyListeners();
  }

  Future<void> addZone(SafeZone zone) async {
    _zones.add(zone);
    notifyListeners();
    await _persistZones();
  }

  Future<void> removeZone(String id) async {
    _zones.removeWhere((z) => z.id == id);
    notifyListeners();
    await _persistZones();
  }

  /// Create a safe zone locally and return the mesh message to broadcast it
  /// (e.g. a resident marking a shelter), so it also reaches offline peers.
  EmergencyMessage createZoneBroadcast(SafeZone zone) {
    return EmergencyMessage(
      id: zone.id,
      senderId: zone.name,
      senderName: zone.name,
      message: '$zonePrefix${jsonEncode(zone.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.low,
      latitude: zone.latitude,
      longitude: zone.longitude,
      timestamp: DateTime.now(),
    );
  }

  /// Create a safe route locally (e.g. a resident marking a clear
  /// evacuation path) and return the mesh message to broadcast it.
  EmergencyMessage createRoute({
    required String name,
    required String description,
    required String safeFrom,
    required List<LatLng> points,
    required String source,
  }) {
    final route = SafeRoute(
      id: const Uuid().v4(),
      name: name,
      description: description,
      safeFrom: safeFrom,
      points: points,
      source: source,
      timestamp: DateTime.now(),
    );
    _routes[route.id] = route;
    notifyListeners();
    _persistRoutes();

    return EmergencyMessage(
      id: route.id,
      senderId: source,
      senderName: source,
      message: '$routePrefix${jsonEncode(route.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.medium,
      latitude: points.first.latitude,
      longitude: points.first.longitude,
      timestamp: route.timestamp,
    );
  }

  /// Absorb a safe zone from an external/authoritative source — e.g. a
  /// government feed announcing an official shelter — and return the mesh
  /// message to broadcast, so it reaches nearby devices with no internet.
  EmergencyMessage ingestExternalZone(SafeZone zone) {
    if (!_zones.any((z) => z.id == zone.id)) {
      _zones.add(zone);
      notifyListeners();
      _persistZones();
    }
    return EmergencyMessage(
      id: zone.id,
      senderId: 'official',
      senderName: zone.name,
      message: '$zonePrefix${jsonEncode(zone.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.medium,
      latitude: zone.latitude,
      longitude: zone.longitude,
      timestamp: DateTime.now(),
    );
  }

  /// Absorb a safe route from an external/authoritative source — e.g. a
  /// government feed announcing "this road is clear of the landslide" —
  /// and return the mesh message to broadcast it further offline.
  EmergencyMessage ingestExternalRoute(SafeRoute route) {
    _routes[route.id] = route;
    notifyListeners();
    _persistRoutes();

    return EmergencyMessage(
      id: route.id,
      senderId: 'official',
      senderName: route.source,
      message: '$routePrefix${jsonEncode(route.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.high,
      latitude: route.points.first.latitude,
      longitude: route.points.first.longitude,
      timestamp: route.timestamp,
    );
  }

  /// Scan mesh messages for safe-zone/safe-route payloads and absorb any
  /// new ones — this is how an official announcement relayed by one phone
  /// with internet reaches every nearby phone with none.
  void syncFromMesh(List<EmergencyMessage> meshMessages) {
    bool added = false;
    for (final m in meshMessages) {
      if (m.message.startsWith(zonePrefix)) {
        try {
          final json = jsonDecode(m.message.substring(zonePrefix.length));
          final z = SafeZone.fromJson(json);
          if (!_zones.any((existing) => existing.id == z.id)) {
            _zones.add(z);
            added = true;
          }
        } catch (_) {}
      } else if (m.message.startsWith(routePrefix)) {
        try {
          final json = jsonDecode(m.message.substring(routePrefix.length));
          final r = SafeRoute.fromJson(json);
          if (!_routes.containsKey(r.id) && !r.isExpired) {
            _routes[r.id] = r;
            added = true;
          }
        } catch (_) {}
      }
    }
    if (added) {
      notifyListeners();
      _persistZones();
      _persistRoutes();
    }
  }

  Future<void> removeRoute(String id) async {
    _routes.remove(id);
    notifyListeners();
    await _persistRoutes();
  }

  Future<void> _persistZones() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _zonesStorageKey,
      jsonEncode(_zones.map((z) => z.toJson()).toList()),
    );
  }

  Future<void> _persistRoutes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _routesStorageKey,
      jsonEncode(_routes.values.map((r) => r.toJson()).toList()),
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