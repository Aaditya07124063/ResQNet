import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'hazard_service.dart';
import 'mesh_service.dart';

/// Polls an external disaster-alert feed (e.g. a government flood/fire
/// warning API) and turns each alert into a [Hazard] via [HazardService],
/// which then broadcasts it over the mesh network — so once one phone with
/// internet receives an official alert, it relays to every nearby phone
/// with none.
///
/// This is the single integration point for hooking up a real feed later:
///
/// 1. Set [feedUrl] to the authority's API endpoint.
/// 2. Update [_parseAlert] to match that endpoint's JSON shape.
///
/// Nothing else in the app needs to change — the map, dashboard, and mesh
/// relay already treat every [Hazard] the same, whether it came from a
/// nearby peer or an official feed.
class GovernmentAlertFeedService {
  /// Placeholder — empty means no feed is configured, so [start] no-ops.
  /// Replace with the real government/authority alert API URL when one is
  /// available.
  static const String feedUrl = '';

  final HazardService hazardService;
  final MeshService meshService;
  Timer? _pollTimer;

  GovernmentAlertFeedService(this.hazardService, this.meshService);

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
      for (final item in list) {
        final hazard = _parseAlert(item as Map<String, dynamic>);
        if (hazard == null) continue;
        final msg = hazardService.ingestExternal(hazard);
        meshService.broadcastMessage(msg);
      }
    } catch (_) {
      // The feed being unreachable is expected while offline — never let
      // it surface as an error to the user.
    }
  }

  /// Adjust field names here to match the real feed's response shape.
  Hazard? _parseAlert(Map<String, dynamic> json) {
    try {
      return Hazard(
        id: json['id'].toString(),
        type: json['type'] as String? ?? 'other',
        description: json['description'] as String? ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        timestamp:
            DateTime.tryParse(json['timestamp'] as String? ?? '') ??
                DateTime.now(),
        reporter: json['source'] as String? ?? 'Government Alert',
      );
    } catch (_) {
      return null;
    }
  }
}
