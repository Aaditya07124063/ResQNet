import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/emergency_message.dart';

/// Where a hazard report originated — distinct from [Hazard.reporter]
/// (a human-readable attribution string for display). Never inferred
/// from message content; always set explicitly by whichever code path
/// constructs the [Hazard] (HazardService.createHazard for a peer's own
/// report, GovernmentAlertFeedService for an official feed).
enum HazardSource { peerReported, officialFeed }

/// How serious this hazard is, per the REPORTER's own assessment — not an
/// independently verified severity. Kept as a small fixed enum (validated
/// on parse, never trusting an arbitrary string from mesh input) rather
/// than a free-text field, per Phase H's "define allowed enums" requirement.
enum HazardSeverity { low, moderate, high, severe }

/// Lifecycle status — kept explicit and separate from mere time-based
/// expiry, so a hazard can also be marked [retracted] (the reporter or an
/// official source withdrew it) without waiting for its TTL to lapse, and
/// so "no longer active" always has one authoritative reason, not just an
/// inferred timestamp comparison.
enum HazardStatus { active, expired, retracted, unconfirmed }

class Hazard {
  final String id;
  final HazardSource source;
  final String type; // flood, fire, powerline, landslide, road_blocked, other
  final HazardSeverity severity;
  final String description;
  final double latitude;
  final double longitude;
  /// Approximate affected radius in meters, when known — the simplest
  /// geometry that represents "an area", not just a point. Null means
  /// "point location only, extent unknown" — never fabricated.
  final double? radiusM;
  /// When the hazard itself was actually observed (may predate when this
  /// device first heard about it, e.g. a government feed reporting a
  /// flood that started hours ago).
  final DateTime observedAt;
  /// When this record was first published/created — for a peer report
  /// this equals [observedAt]; for a relayed/fed report it's when the
  /// publishing source (not this device) issued it.
  final DateTime publishedAt;
  /// Explicit expiry — no longer inferred purely from "hours since
  /// timestamp". Required so staleness has one unambiguous definition
  /// shared by every code path, including hazards ingested from an
  /// external feed with its own stated validity window.
  final DateTime expiresAt;
  /// The REPORTER's own confidence in their report (0.0-1.0) — e.g. 1.0
  /// for "I am looking at this right now", lower for a secondhand
  /// account. Never an objective/ground-truth confidence score this app
  /// has no way to compute.
  final double confidence;
  final HazardStatus status;
  final String reporter;

  Hazard({
    required this.id,
    this.source = HazardSource.peerReported,
    required this.type,
    this.severity = HazardSeverity.moderate,
    required this.description,
    required this.latitude,
    required this.longitude,
    this.radiusM,
    DateTime? observedAt,
    DateTime? publishedAt,
    DateTime? expiresAt,
    this.confidence = 1.0,
    this.status = HazardStatus.active,
    required this.reporter,
  })  : observedAt = observedAt ?? publishedAt ?? DateTime.now(),
        publishedAt = publishedAt ?? observedAt ?? DateTime.now(),
        expiresAt = expiresAt ?? (publishedAt ?? observedAt ?? DateTime.now()).add(const Duration(hours: 24));

  /// Backward-compatible accessor — every existing call site
  /// (map_screen.dart, government_alert_feed_service.dart,
  /// hazard_service.dart's own mesh sync) that reads `.timestamp` keeps
  /// working unchanged; it now reads [publishedAt], the closest existing
  /// concept to what "timestamp" meant before this model was extended.
  DateTime get timestamp => publishedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.name,
        'type': type,
        'severity': severity.name,
        'description': description,
        'latitude': latitude,
        'longitude': longitude,
        'radiusM': radiusM,
        'observedAt': observedAt.toIso8601String(),
        'publishedAt': publishedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'confidence': confidence,
        'status': status.name,
        'reporter': reporter,
        // Retained for exact wire-compatibility with any peer still
        // running a pre-Phase-H build of this app, which only understands
        // this one field for recency.
        'timestamp': publishedAt.toIso8601String(),
      };

  /// Never throws on malformed/adversarial input — from a mesh peer, or
  /// from this device's OWN previously-persisted local storage (a record
  /// written by an older/incompatible build, or corrupted on disk).
  /// Every field is either defensively defaulted, or — for the three
  /// fields with no safe default (`id`, `latitude`, `longitude`) —
  /// causes this factory to return `null` (reject the record entirely)
  /// rather than fabricate an identity or a location. Silently defaulting
  /// a hazard's coordinates to e.g. 0,0 would be actively dangerous (a
  /// flood warning appearing to be "at" Null Island is worse than no
  /// warning); silently inventing an id would break deduplication. Every
  /// call site (`load()`, `syncFromMesh()`) must treat a `null` result as
  /// "drop this one record, keep processing the rest" — never abort the
  /// whole batch.
  static Hazard? fromJson(Map<String, dynamic> json) {
    // `T extends Enum` makes `.name` a statically-resolved member access,
    // not a dynamic one — calling `.name` via `(v as dynamic).name` on a
    // generic-typed enum value was tried first and found, by an actual
    // failing test, to throw NoSuchMethodError at runtime in this
    // toolchain (a real, reproducible dynamic-interface/tree-shaking
    // limitation, not a hypothetical one) — this bounded-generic form
    // avoids dynamic dispatch entirely and is the correct fix, not a
    // workaround.
    T parseEnum<T extends Enum>(List<T> values, dynamic raw, T fallback) {
      if (raw is! String) return fallback;
      for (final v in values) {
        if (v.name == raw) return v;
      }
      return fallback;
    }

    final id = json['id'];
    if (id is! String || id.isEmpty) return null;

    final rawLat = json['latitude'];
    final rawLng = json['longitude'];
    if (rawLat is! num || rawLng is! num) return null;
    // Reject a structurally-numeric-but-physically-impossible coordinate
    // too (e.g. a corrupted/overflowed value) — the same "don't fabricate
    // a location" reasoning as above.
    if (rawLat < -90 || rawLat > 90 || rawLng < -180 || rawLng > 180) return null;

    final publishedAt = DateTime.tryParse(json['publishedAt'] as String? ?? json['timestamp'] as String? ?? '');
    final observedAt = DateTime.tryParse(json['observedAt'] as String? ?? '');
    final expiresAt = DateTime.tryParse(json['expiresAt'] as String? ?? '');

    return Hazard(
      id: id,
      source: parseEnum(HazardSource.values, json['source'], HazardSource.peerReported),
      type: json['type'] as String? ?? 'other',
      severity: parseEnum(HazardSeverity.values, json['severity'], HazardSeverity.moderate),
      description: json['description'] as String? ?? '',
      latitude: rawLat.toDouble(),
      longitude: rawLng.toDouble(),
      radiusM: (json['radiusM'] as num?)?.toDouble(),
      observedAt: observedAt,
      publishedAt: publishedAt,
      expiresAt: expiresAt,
      confidence: (json['confidence'] as num?)?.toDouble().clamp(0.0, 1.0) ?? 1.0,
      status: parseEnum(HazardStatus.values, json['status'], HazardStatus.active),
      reporter: json['reporter'] as String? ?? 'Unknown',
    );
  }

  /// True once past [expiresAt] OR explicitly [HazardStatus.retracted] —
  /// a retracted hazard must never keep showing as active just because
  /// its TTL hasn't lapsed yet. An [HazardStatus.expired]/[unconfirmed]
  /// status set explicitly by a source also counts, independent of the
  /// timestamp — status is authoritative when present.
  bool get isExpired =>
      status == HazardStatus.retracted ||
      status == HazardStatus.expired ||
      DateTime.now().isAfter(expiresAt);

  /// Human-readable freshness for UI display (Phase 12: "Last hazard
  /// update: 42 minutes ago" is acceptable; never claim something is
  /// "live" when it's actually this old). Based on [publishedAt] — when
  /// THIS device/the feed actually issued the record, not when it happened.
  String get freshnessLabel {
    final age = DateTime.now().difference(publishedAt);
    if (age.inMinutes < 1) return 'Just now';
    if (age.inMinutes < 60) return '${age.inMinutes} min ago';
    if (age.inHours < 24) return '${age.inHours} hr ago';
    return '${age.inDays} day${age.inDays == 1 ? '' : 's'} ago';
  }

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
    if (raw == null) return;
    List<dynamic> list;
    try {
      list = jsonDecode(raw) as List;
    } catch (_) {
      // The entire persisted blob is corrupted (not even valid JSON/not a
      // list) — nothing to salvage, but this must not crash startup.
      return;
    }
    for (final e in list) {
      // A single malformed/corrupted persisted record (e.g. written by an
      // older/incompatible build, or a non-object entry) must never abort
      // loading every OTHER hazard — skip just that one.
      try {
        final h = Hazard.fromJson(e as Map<String, dynamic>);
        if (h != null && !h.isExpired) _hazards[h.id] = h;
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Create a hazard locally and return the mesh message to broadcast it.
  /// [severity]/[confidence]/[radiusM] are optional — a civilian reporting
  /// from the map screen today has no UI to specify these yet, so they
  /// default to "moderate severity, full reporter confidence, point
  /// location" rather than requiring every existing call site to change.
  EmergencyMessage createHazard({
    required String type,
    required String description,
    required double latitude,
    required double longitude,
    required String reporter,
    HazardSeverity severity = HazardSeverity.moderate,
    double confidence = 1.0,
    double? radiusM,
  }) {
    final now = DateTime.now();
    final hazard = Hazard(
      id: const Uuid().v4(),
      source: HazardSource.peerReported,
      type: type,
      severity: severity,
      description: description,
      latitude: latitude,
      longitude: longitude,
      radiusM: radiusM,
      observedAt: now,
      publishedAt: now,
      confidence: confidence,
      status: HazardStatus.active,
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
        final json = jsonDecode(m.message.substring(hazardPrefix.length)) as Map<String, dynamic>;
        final h = Hazard.fromJson(json);
        if (h != null && !_hazards.containsKey(h.id) && !h.isExpired) {
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