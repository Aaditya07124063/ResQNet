import 'dart:async';
import 'package:flutter/foundation.dart';
import '../network/api_client.dart';
import 'hazard_service.dart';
import 'mesh_service.dart';
import 'safe_zone_service.dart';

/// Brings emergency alerts from the ResQNet server (`GET /api/v1/alerts`)
/// onto the map. The server is the single integration point for external
/// authorities and feeds: it normalizes each source and labels it
/// (official, verified partner, ResQNet, community, device sensor), so the
/// app never has to trust a feed directly.
///
/// - The label shown in the app comes from the server's `sourceType`, never
///   from the alert text.
/// - Alerts are also relayed over the mesh so nearby phones without
///   Internet see them; receiving phones show them as unverified community
///   reports, because mesh hazards are unsigned (see HazardService).
/// - Alerts the server no longer lists (resolved, cancelled, expired) are
///   removed from the map on the next successful poll.
/// - Alerts scoped only to an administrative area (no coordinates) cannot be
///   drawn as a point yet and are skipped.
class GovernmentAlertFeedService {
  GovernmentAlertFeedService(this.hazardService, this.safeZoneService, this.meshService);

  static const _idPrefix = 'alert:';

  final HazardService hazardService;
  final SafeZoneService safeZoneService;
  final MeshService meshService;
  Timer? _pollTimer;
  final Set<String> _relayed = {};

  void start({Duration interval = const Duration(minutes: 15)}) {
    unawaited(pollNow());
    _pollTimer = Timer.periodic(interval, (_) => pollNow());
  }

  void stop() => _pollTimer?.cancel();

  @visibleForTesting
  Future<void> pollNow() async {
    Map<String, dynamic> response;
    try {
      response = await ApiClient.instance.get('/alerts', auth: false);
    } catch (e) {
      // Offline or server unreachable: keep what is already on the map.
      debugPrint('Alert feed unavailable: $e');
      return;
    }

    final active = <String>{};
    for (final raw in (response['alerts'] as List?) ?? const []) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'];
      if (id is! String) continue;
      final localId = '$_idPrefix$id';
      active.add(localId);
      final area = raw['area'] as Map<String, dynamic>? ?? const {};
      final lat = (area['latitude'] as num?)?.toDouble();
      final lng = (area['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;

      if (raw['category'] == 'shelter') {
        final message = safeZoneService.ingestExternalZone(SafeZone(
          id: localId,
          name: raw['title'] as String? ?? 'Shelter',
          latitude: lat,
          longitude: lng,
          type: 'shelter',
        ));
        _relayOnce(localId, message);
        continue;
      }

      final hazard = Hazard.fromServerAlert(raw);
      if (hazard == null) continue;
      _relayOnce(localId, hazardService.ingestExternal(hazard));
    }

    // Remove server alerts that are no longer active.
    for (final h in hazardService.hazards.where((h) => h.id.startsWith(_idPrefix)).toList()) {
      if (!active.contains(h.id)) await hazardService.removeHazard(h.id);
    }
    for (final z in safeZoneService.zones.where((z) => z.id.startsWith(_idPrefix)).toList()) {
      if (!active.contains(z.id)) await safeZoneService.removeZone(z.id);
    }
  }

  void _relayOnce(String id, dynamic message) {
    if (_relayed.add(id)) unawaited(meshService.broadcastMessage(message));
  }
}

/// Maps a server alert to a map hazard (see [Hazard.fromServerAlert]).
@visibleForTesting
Hazard? hazardFromAlert(Map<String, dynamic> alert,
        {required String localId, required double latitude, required double longitude}) =>
    Hazard.fromServerAlert(alert);
