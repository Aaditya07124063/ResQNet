import 'dart:io';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'map/map_tile_provider.dart';
import 'map/offline_map_region_store.dart';

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
  /// Persists the ONE auto-cache region's id across runs, so every
  /// 6-hourly refresh reuses the same FMTC store instead of minting a
  /// fresh one forever — left unbounded, that would silently accumulate
  /// one new "Auto-cached area" region (and its own FMTC store) every 6
  /// hours for the lifetime of the install, none of them ever cleaned up.
  /// A user-initiated download (map_screen.dart's "Download area for
  /// offline use") is unaffected — it always gets its own new region,
  /// since the user explicitly means to add a new, separately-manageable
  /// area, not refresh the background one.
  static const _autoCacheRegionIdKey = 'auto_cache_region_id_v1';
  static const _throttle = Duration(hours: 6);
  static const double _radiusKm = 5;

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

      // ONE source of truth for the tile URL/attribution/user-agent —
      // see map/map_tile_provider.dart's own doc comment on why this
      // used to be a separately-hardcoded constant here and in
      // map_screen.dart, and why that was a real duplication problem.
      final provider = resolveMapTileProvider();
      final center = LatLng(position.latitude, position.longitude);
      final downloadable = CircleRegion(center, _radiusKm).toDownloadable(
        minZoom: 12,
        maxZoom: 16,
        options: TileLayer(
          urlTemplate: provider.urlTemplate,
          userAgentPackageName: provider.userAgentPackageName,
        ),
      );

      // Reuse the SAME auto-cache region across every 6-hourly refresh
      // (see _autoCacheRegionIdKey's own doc comment) — only allocate a
      // new one the first time ever, or if the previously-recorded
      // region's store has gone missing for any reason.
      var regionId = prefs.getString(_autoCacheRegionIdKey);
      if (regionId == null || !await FMTCStore(OfflineMapRegionStore.regionStoreName(regionId)).manage.ready) {
        regionId = await OfflineMapRegionStore.instance.beginRegion();
        await prefs.setString(_autoCacheRegionIdKey, regionId);
      }
      final store = FMTCStore(OfflineMapRegionStore.regionStoreName(regionId));
      await store.download
          .startForeground(
            region: downloadable,
            parallelThreads: 3,
            skipExistingTiles: true,
            skipSeaTiles: true,
          )
          .drain<void>();

      await prefs.setInt(
          _lastAutoCacheKey, DateTime.now().millisecondsSinceEpoch);

      // Phase J region bookkeeping — records this auto-cached area as an
      // offline-available region (best-effort; a failure here must not
      // undo the successful tile download above).
      try {
        await OfflineMapRegionStore.instance.recordDownloadedRegion(
          id: regionId,
          label: 'Auto-cached area',
          center: center,
          radiusKm: _radiusKm,
        );
      } catch (_) {
        // Non-fatal — the tiles are still cached and usable even if this
        // bookkeeping step fails.
      }
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
