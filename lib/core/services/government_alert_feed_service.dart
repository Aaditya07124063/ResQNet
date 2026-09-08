import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'hazard_service.dart';
import 'mesh_service.dart';
import 'safe_zone_service.dart';

/// Polls an external disaster-alert feed (e.g. a government flood/fire
/// warning API) and turns each entry into either a [Hazard] (danger to
/// avoid) or a [SafeZone]/[SafeRoute] (shelter or path confirmed safe —
/// e.g. "this road is clear of the landslide"), via [HazardService] and
/// [SafeZoneService]. Either way the result then broadcasts over the mesh
/// network — so once one phone with internet receives an official
/// announcement, it relays to every nearby phone with none.
///
/// This is the single integration point for hooking up a real feed later:
///
/// 1. Set [feedUrl] to the authority's API endpoint.
/// 2. Update [_parseAlert] to match that endpoint's JSON shape. Each item's
///    `type` field decides what it becomes:
///    - `"safe_route"` → a [SafeRoute] (needs a `points` array of
///      `[lat, lng]` pairs, plus optional `safeFrom`/`name`/`description`).
///    - `"safe_zone"` → a [SafeZone] (needs `latitude`/`longitude`, plus
///      optional `name`/`zoneType`).
///    - anything else (`"flood"`, `"fire"`, `"landslide"`,
///      `"powerline"`, `"road_blocked"`, ...) → a [Hazard].
///
/// Nothing else in the app needs to change — the map, dashboard, and mesh
/// relay already treat every hazard/safe zone/safe route the same, whether
/// it came from a nearby peer or an official feed.
class GovernmentAlertFeedService {
  /// Placeholder — empty means no feed is configured, so [start] no-ops.
  /// Replace with the real government/authority alert API URL when one is
  /// available.
  static const String feedUrl = '';

  final HazardService hazardService;
  final SafeZoneService safeZoneService;
  final MeshService meshService;
  Timer? _pollTimer;

  GovernmentAlertFeedService(
      this.hazardService, this.safeZoneService, this.meshService);

  void start({Duration interval = const Duration(minutes: 15)}) {
    if (feedUrl.isEmpty) return;
    _poll();
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void stop() => _pollTimer?.cancel();

  Future<void> _poll() async {
    try {
      final response = await http
          .get(Uri.parse(feedUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;

      final list = jsonDecode(response.body) as List;
      for (final raw in list) {
        final item = raw as Map<String, dynamic>;
        final type = item['type'] as String?;

        if (type == 'safe_route') {
          final route = _parseSafeRoute(item);
          if (route == null) continue;
          meshService.broadcastMessage(
              safeZoneService.ingestExternalRoute(route));
        } else if (type == 'safe_zone') {
          final zone = _parseSafeZone(item);
          if (zone == null) continue;
          meshService
              .broadcastMessage(safeZoneService.ingestExternalZone(zone));
        } else {
          final hazard = _parseAlert(item);
          if (hazard == null) continue;
          meshService.broadcastMessage(hazardService.ingestExternal(hazard));
        }
      }
    } catch (_) {
      // The feed being unreachable is expected while offline — never let
      // it surface as an error to the user.
    }
  }

  /// Adjust field names here to match the real feed's response shape.
  Hazard? _parseAlert(Map<String, dynamic> json) {
    try {
      final publishedAt =
          DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now();
      return Hazard(
        id: json['id'].toString(),
        source: HazardSource.officialFeed,
        type: json['type'] as String? ?? 'other',
        // A named, official source is treated as a higher-confidence
        // report than an anonymous peer's by default — still not claimed
        // as independently verified ground truth, just a reasonable
        // default distinct from a bystander's own eyewitness confidence.
        confidence: 0.9,
        description: json['description'] as String? ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        observedAt: publishedAt,
        publishedAt: publishedAt,
        reporter: json['source'] as String? ?? 'Government Alert',
      );
    } catch (_) {
      return null;
    }
  }

  SafeZone? _parseSafeZone(Map<String, dynamic> json) {
    try {
      return SafeZone(
        id: json['id'].toString(),
        name: json['name'] as String? ?? 'Official safe zone',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        type: json['zoneType'] as String? ?? 'shelter',
      );
    } catch (_) {
      return null;
    }
  }

  SafeRoute? _parseSafeRoute(Map<String, dynamic> json) {
    try {
      final rawPoints = json['points'] as List;
      final points = rawPoints
          .map((p) => LatLng(
              ((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()))
          .toList();
      if (points.isEmpty) return null;
      return SafeRoute(
        id: json['id'].toString(),
        name: json['name'] as String? ?? 'Official safe route',
        description: json['description'] as String? ?? '',
        safeFrom: json['safeFrom'] as String? ?? 'general',
        points: points,
        source: json['source'] as String? ?? 'Government Alert',
        timestamp:
            DateTime.tryParse(json['timestamp'] as String? ?? '') ??
                DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}
