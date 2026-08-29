import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';

class Hazard {
  final String id;
  final String type; // flood, fire, powerline, landslide, road_blocked, other
  final String description;
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final String reporter;

  Hazard({
    required this.id,
    required this.type,
    required this.description,
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.reporter,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'description': description,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp.toIso8601String(),
        'reporter': reporter,
      };

  factory Hazard.fromJson(Map<String, dynamic> json) => Hazard(
        id: json['id'],
        type: json['type'] ?? 'other',
        description: json['description'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        timestamp: DateTime.parse(json['timestamp']),
        reporter: json['reporter'] ?? 'Unknown',
      );

  bool get isExpired => DateTime.now().difference(timestamp).inHours >= 24;

  IconData get icon {
    switch (type) {
      case 'flood':
        return Icons.water;
      case 'fire':
        return Icons.local_fire_department;
      case 'powerline':
        return Icons.electric_bolt;
      case 'landslide':
        return Icons.landslide;
      case 'road_blocked':
        return Icons.block;
      default:
        return Icons.warning;
    }
  }

  Color get color {
    switch (type) {
      case 'flood':
        return Colors.blue;
      case 'fire':
        return Colors.deepOrange;
      case 'powerline':
        return Colors.amber.shade800;
      case 'landslide':
        return Colors.brown;
      case 'road_blocked':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  String get typeLabel {
    switch (type) {
      case 'flood':
        return 'Flooded Area';
      case 'fire':
        return 'Fire';
      case 'powerline':
        return 'Downed Powerline';
      case 'landslide':
        return 'Landslide';
      case 'road_blocked':
        return 'Road Blocked';
      default:
        return 'Hazard';
    }
  }
}

class HazardService extends ChangeNotifier {
  static const _storageKey = 'hazards';
  static const hazardPrefix = 'HAZARD|';

  final Map<String, Hazard> _hazards = {};

  List<Hazard> get hazards =>
      _hazards.values.where((h) => !h.isExpired).toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        final h = Hazard.fromJson(e);
        if (!h.isExpired) _hazards[h.id] = h;
      }
      notifyListeners();
    }
  }

  /// Create a hazard locally and return the mesh message to broadcast it.
  EmergencyMessage createHazard({
    required String type,
    required String description,
    required double latitude,
    required double longitude,
    required String reporter,
  }) {
    final hazard = Hazard(
      id: const Uuid().v4(),
      type: type,
      description: description,
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.now(),
      reporter: reporter,
    );
    _hazards[hazard.id] = hazard;
    notifyListeners();
    _persist();

    // Encode hazard as a mesh message with the HAZARD| prefix
    return EmergencyMessage(
      id: hazard.id,
      senderId: reporter,
      senderName: reporter,
      message: '$hazardPrefix${jsonEncode(hazard.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.medium,
      latitude: latitude,
      longitude: longitude,
      timestamp: hazard.timestamp,
    );
  }

  /// Absorb a hazard from an external/authoritative source — e.g. a future
  /// government disaster-alert feed — and return the mesh message to
  /// broadcast, so the alert also reaches nearby devices with no internet.
  EmergencyMessage ingestExternal(Hazard hazard) {
    _hazards[hazard.id] = hazard;
    notifyListeners();
    _persist();

    return EmergencyMessage(
      id: hazard.id,
      senderId: 'official',
      senderName: hazard.reporter,
      message: '$hazardPrefix${jsonEncode(hazard.toJson())}',
      type: EmergencyType.general,
      priority: PriorityLevel.high,
      latitude: hazard.latitude,
      longitude: hazard.longitude,
      timestamp: hazard.timestamp,
    );
  }

  /// Scan mesh messages for hazard payloads and absorb any new ones.
  void syncFromMesh(List<EmergencyMessage> meshMessages) {
    bool added = false;
    for (final m in meshMessages) {
      if (!m.message.startsWith(hazardPrefix)) continue;
      try {
        final json = jsonDecode(m.message.substring(hazardPrefix.length));
        final h = Hazard.fromJson(json);
        if (!_hazards.containsKey(h.id) && !h.isExpired) {
          _hazards[h.id] = h;
          added = true;
        }
      } catch (_) {}
    }
    if (added) {
      notifyListeners();
      _persist();
    }
  }

  Future<void> removeHazard(String id) async {
    _hazards.remove(id);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode(_hazards.values.map((h) => h.toJson()).toList()),
    );
  }
}