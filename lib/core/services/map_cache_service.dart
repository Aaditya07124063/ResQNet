import 'dart:io';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps a small map area around the user cached for offline use, without
/// requiring them to remember to press "download" before a disaster hits.
///
/// A disaster doesn't announce itself in advance, so instead of asking the
/// user to predict one, this silently refreshes a modest radius around
/// wherever they already are, any time the app has both GPS and internet.
/// By the time connectivity drops, there's normally already a working local
/// map cached — not just whatever the user manually downloaded once.
class MapCacheService {
  static const _lastAutoCacheKey = 'last_auto_map_cache_millis';
  static const _throttle = Duration(hours: 6);
  static const double _radiusKm = 5;
  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Fire-and-forget: caches tiles near [position] if online and if we
  /// haven't auto-cached recently. Never throws — a failure here must
  /// never block app startup or crash the app.
  static Future<void> autoCacheNearbyArea(Position position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMillis = prefs.getInt(_lastAutoCacheKey);
      if (lastMillis != null) {
        final since = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(lastMillis));
        if (since < _throttle) return;
      }

      final online = await _hasInternet();
      if (!online) return;

      final center = LatLng(position.latitude, position.longitude);
      final downloadable = CircleRegion(center, _radiusKm).toDownloadable(
        minZoom: 12,
        maxZoom: 16,
        options: TileLayer(
          urlTemplate: _tileUrl,
          userAgentPackageName: 'com.resqnet.app',
        ),
      );

      await const FMTCStore('mapStore')
          .download
          .startForeground(
            region: downloadable,
            parallelThreads: 3,
            skipExistingTiles: true,
            skipSeaTiles: true,
          )
          .drain<void>();

      await prefs.setInt(
          _lastAutoCacheKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Best-effort background task — errors are not actionable here.
    }
  }

  static Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('tile.openstreetmap.org')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
