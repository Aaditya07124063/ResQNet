import 'dart:convert';
import 'dart:math';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Whether a location is covered by a previously-downloaded offline map
/// region, and whether that region's underlying tiles are actually
/// intact.
enum MapRegionAvailability {
  available,
  /// A region's metadata claims tiles were downloaded, but its
  /// underlying FMTC store is missing or has zero tiles — the download
  /// never completed, was interrupted, or its store was removed outside
  /// this class. Never silently reported as [available].
  corrupted,
  notDownloaded,
}

/// Metadata for one region a user has explicitly downloaded for offline
/// use.
///
/// Each region owns ITS OWN independent `flutter_map_tile_caching` store
/// (named via [OfflineMapRegionStore.regionStoreName]) — this is what
/// makes per-region deletion genuinely independent: FMTC's ObjectBox
/// backend deduplicates tile bytes by URL and reference-counts which
/// stores reference each tile (verified by reading
/// flutter_map_tile_caching-9.1.4's own
/// `internal_workers/standard/worker.dart` `deleteTiles`/
/// `_sharedWriteSingleTile`), so deleting region A's store only removes
/// A's link to each tile — a tile also downloaded as part of region B
/// survives untouched, and is only physically removed once NO region
/// references it any more. Rendering still works across all regions at
/// once via `FMTCTileProviderSettings.fallbackToAlternativeStore`
/// (true by default) — see [OfflineMapRegionStore.renderStoreName]'s doc
/// comment.
class OfflineMapRegion {
  final String id;
  final String label;
  final double centerLat;
  final double centerLng;
  final double radiusKm;
  final DateTime downloadedAt;
  final int tileCountAtDownload;

  const OfflineMapRegion({
    required this.id,
    required this.label,
    required this.centerLat,
    required this.centerLng,
    required this.radiusKm,
    required this.downloadedAt,
    required this.tileCountAtDownload,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'centerLat': centerLat,
        'centerLng': centerLng,
        'radiusKm': radiusKm,
        'downloadedAt': downloadedAt.toIso8601String(),
        'tileCountAtDownload': tileCountAtDownload,
      };

  factory OfflineMapRegion.fromJson(Map<String, dynamic> json) => OfflineMapRegion(
        id: json['id'] as String,
        label: json['label'] as String,
        centerLat: (json['centerLat'] as num).toDouble(),
        centerLng: (json['centerLng'] as num).toDouble(),
        radiusKm: (json['radiusKm'] as num).toDouble(),
        downloadedAt: DateTime.parse(json['downloadedAt'] as String),
        tileCountAtDownload: json['tileCountAtDownload'] as int,
      );
}

/// Region-level bookkeeping AND per-region tile isolation, on top of
/// `flutter_map_tile_caching`. Each region gets its own named FMTC store
/// (see [OfflineMapRegion]'s doc comment for why this makes deletion
/// genuinely independent between regions, verified against FMTC
/// 9.1.4's actual ObjectBox backend source — not assumed).
class OfflineMapRegionStore {
  OfflineMapRegionStore._();
  static final OfflineMapRegionStore instance = OfflineMapRegionStore._();

  static const _regionsKey = 'resqnet_offline_map_regions_v2';

  /// The store name every render-time `TileLayer.tileProvider` binds to.
  /// It is deliberately never downloaded into directly — it exists only
  /// as an anchor point, because `FMTCTileProviderSettings
  /// .fallbackToAlternativeStore` (true by default, confirmed by reading
  /// flutter_map_tile_caching-9.1.4's `providers/image_provider.dart`)
  /// makes a tile miss in this store transparently check every OTHER
  /// store too, at zero extra network cost — so the map renders tiles
  /// from every downloaded region at once, while each region's own store
  /// (see [regionStoreName]) stays independently deletable.
  static const String renderStoreName = 'map_render_primary';

  static String regionStoreName(String regionId) => 'region_$regionId';

  Future<void> ensureRenderStoreReady() async {
    const store = FMTCStore(renderStoreName);
    if (!await store.manage.ready) {
      await store.manage.create();
    }
  }

  Future<List<OfflineMapRegion>> listRegions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_regionsKey);
    if (raw == null) return <OfflineMapRegion>[];
    try {
      final list = jsonDecode(raw) as List;
      return list.map((e) => OfflineMapRegion.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return <OfflineMapRegion>[];
    }
  }

  Future<void> _saveAll(List<OfflineMapRegion> regions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_regionsKey, jsonEncode(regions.map((r) => r.toJson()).toList()));
  }

  /// Allocates a fresh, globally-unique region id and creates ITS OWN
  /// independent FMTC store — call this BEFORE starting a tile download,
  /// then download into `FMTCStore(OfflineMapRegionStore.regionStoreName(id))`
  /// (e.g. via `.download.startForeground`), and finally call
  /// [recordDownloadedRegion] with the same id once the download
  /// completes.
  Future<String> beginRegion() async {
    final id = const Uuid().v4();
    await FMTCStore(regionStoreName(id)).manage.create();
    return id;
  }

  /// Records a completed region download's metadata. [id] must be one
  /// previously returned by [beginRegion], whose store has already been
  /// downloaded into.
  Future<OfflineMapRegion> recordDownloadedRegion({
    required String id,
    required String label,
    required LatLng center,
    required double radiusKm,
  }) async {
    final tileCount = await regionTileCount(id);
    final region = OfflineMapRegion(
      id: id,
      label: label,
      centerLat: center.latitude,
      centerLng: center.longitude,
      radiusKm: radiusKm,
      downloadedAt: DateTime.now(),
      tileCountAtDownload: tileCount,
    );
    final all = await listRegions();
    all.removeWhere((r) => r.id == id); // re-recording (e.g. a resumed download) replaces, never duplicates
    all.add(region);
    await _saveAll(all);
    return region;
  }

  /// Deletes exactly ONE region: its own FMTC store (physically freeing
  /// any tile not also referenced by another surviving region — see
  /// [OfflineMapRegion]'s doc comment) and its metadata record. Every
  /// OTHER region is left completely untouched, because each has its own
  /// independent store.
  Future<void> deleteRegion(String id) async {
    final store = FMTCStore(regionStoreName(id));
    if (await store.manage.ready) {
      await store.manage.delete();
    }
    final all = await listRegions();
    all.removeWhere((r) => r.id == id);
    await _saveAll(all);
  }

  /// Wipes every downloaded region's tiles and metadata. The dedicated
  /// [renderStoreName] anchor store is left in place (it never holds
  /// region tiles of its own to wipe).
  Future<void> deleteAllRegionsAndTiles() async {
    final all = await listRegions();
    for (final region in all) {
      final store = FMTCStore(regionStoreName(region.id));
      if (await store.manage.ready) {
        await store.manage.delete();
      }
    }
    await _saveAll(<OfflineMapRegion>[]);
  }

  Future<int> regionTileCount(String id) async {
    final store = FMTCStore(regionStoreName(id));
    if (!await store.manage.ready) return 0;
    return store.stats.length;
  }

  Future<double> regionSizeKib(String id) async {
    final store = FMTCStore(regionStoreName(id));
    if (!await store.manage.ready) return 0;
    return store.stats.size;
  }

  /// Total physical storage used by ALL downloaded regions combined,
  /// from FMTC's own root statistics — already deduplicated, so a tile
  /// shared by two overlapping regions is only counted once. This is the
  /// figure to show for "offline map storage usage", not a naive sum of
  /// each region's own tile count (which would double-count overlap).
  Future<int> totalTileCount() => FMTCRoot.stats.length;

  Future<double> totalSizeKib() => FMTCRoot.stats.size;

  /// A region is corrupted/incomplete if its store no longer exists, or
  /// exists but currently holds no tiles at all despite metadata
  /// recording a completed download — e.g. the store was removed outside
  /// this class, or a download was interrupted before any tile was
  /// written. Partial tile loss between "some" and "all" (e.g. from a
  /// future eviction policy) is not distinguished from full health here;
  /// that would need per-tile-coordinate verification against the
  /// original download region, which this class does not attempt —
  /// documented, not silently assumed away.
  Future<bool> isRegionHealthy(OfflineMapRegion region) async {
    final store = FMTCStore(regionStoreName(region.id));
    if (!await store.manage.ready) return false;
    if (region.tileCountAtDownload == 0) return true; // nothing was ever expected
    final currentCount = await store.stats.length;
    return currentCount > 0;
  }

  /// Whether [point] falls inside any previously-downloaded region, and
  /// whether that region's tiles are actually intact. Returns
  /// [MapRegionAvailability.available] if at least one covering region
  /// is healthy, [MapRegionAvailability.corrupted] if every covering
  /// region has failed its health check, and
  /// [MapRegionAvailability.notDownloaded] if no region covers the point
  /// at all.
  Future<MapRegionAvailability> checkAvailability(LatLng point) async {
    final regions = await listRegions();
    final covering = regions.where((region) {
      final distanceKm = _haversineKm(point.latitude, point.longitude, region.centerLat, region.centerLng);
      return distanceKm <= region.radiusKm;
    }).toList();
    if (covering.isEmpty) return MapRegionAvailability.notDownloaded;
    for (final region in covering) {
      if (await isRegionHealthy(region)) return MapRegionAvailability.available;
    }
    return MapRegionAvailability.corrupted;
  }

  static double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusKm = 6371.0;
    double toRad(double deg) => deg * pi / 180;
    final dLat = toRad(lat2 - lat1);
    final dLng = toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(toRad(lat1)) * cos(toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
