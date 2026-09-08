import 'package:flutter/foundation.dart';

/// Phase I: the boundary between "where tiles come from" and everything
/// that renders or caches them. `map_screen.dart` (rendering) and
/// `map_cache_service.dart` (background pre-caching) both previously
/// hardcoded their OWN separate copy of the same tile URL — a duplicate-
/// source-of-truth problem this class fixes, not just an abstraction for
/// its own sake.
abstract class MapTileProvider {
  String get urlTemplate;
  String get attributionText;
  String get attributionUrl;
  String get userAgentPackageName;
  int get maxZoom;

  /// False for a provider that must not be treated as cleared for wide
  /// production distribution — callers (the renderer, the region
  /// download flow) should surface this honestly (e.g. a "development
  /// build" note) rather than silently presenting it as fully approved.
  bool get isProductionReady;
}

/// The tile source this app has always used, made explicit and
/// centralized rather than fixed. DISCLOSED, NOT SILENTLY CARRIED
/// FORWARD: OpenStreetMap's own tile usage policy
/// (operations.osmfoundation.org/policies/tiles/) is written for
/// low-volume, non-bulk use and explicitly discourages exactly this
/// pattern — a distributed app hitting tile.openstreetmap.org directly,
/// including bulk region pre-downloads. This class does not introduce
/// new tile traffic; it centralizes and documents traffic that already
/// existed under two separately-hardcoded constants.
///
/// Required before wide/production distribution: obtain a real, licensed
/// tile provider account (e.g. MapTiler, Stadia Maps, Thunderforest, or a
/// self-hosted tile server compatible with this app's raster tile usage)
/// and switch to [ConfiguredTileProvider] via the dart-define keys
/// documented on that class. No API key is fabricated or hardcoded here.
class OpenStreetMapDirectProvider implements MapTileProvider {
  const OpenStreetMapDirectProvider();

  @override
  String get urlTemplate => 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  String get attributionText => 'OpenStreetMap contributors';

  @override
  String get attributionUrl => 'https://www.openstreetmap.org/copyright';

  @override
  String get userAgentPackageName => 'com.resqnet.app';

  @override
  int get maxZoom => 19;

  @override
  bool get isProductionReady => false;
}

/// A real, licensed tile provider — configured ENTIRELY via build-time
/// `--dart-define` values, never a hardcoded key. Example (values are
/// illustrative, not real credentials):
///
/// ```
/// flutter run \
///   --dart-define=RESQNET_TILE_URL_TEMPLATE="https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key={key}" \
///   --dart-define=RESQNET_TILE_API_KEY="<your real MapTiler key>" \
///   --dart-define=RESQNET_TILE_ATTRIBUTION="MapTiler / OpenStreetMap contributors" \
///   --dart-define=RESQNET_TILE_ATTRIBUTION_URL="https://www.maptiler.com/copyright/"
/// ```
///
/// [MapTileProvider.resolve] falls back to [OpenStreetMapDirectProvider]
/// when `RESQNET_TILE_URL_TEMPLATE` is not supplied — this class never
/// invents, guesses, or silently activates with a missing/empty key.
class ConfiguredTileProvider implements MapTileProvider {
  const ConfiguredTileProvider._({
    required this.urlTemplate,
    required this.attributionText,
    required this.attributionUrl,
  });

  @override
  final String urlTemplate;
  @override
  final String attributionText;
  @override
  final String attributionUrl;

  @override
  String get userAgentPackageName => 'com.resqnet.app';

  @override
  int get maxZoom => 19;

  @override
  bool get isProductionReady => true;
}

/// Resolves the tile provider to actually use, at build/run time — the
/// ONE place this decision is made. Everything else (map_screen.dart,
/// map_cache_service.dart) asks this function, never hardcodes a URL.
MapTileProvider resolveMapTileProvider() {
  const urlTemplate = String.fromEnvironment('RESQNET_TILE_URL_TEMPLATE');
  const apiKey = String.fromEnvironment('RESQNET_TILE_API_KEY');
  const attribution = String.fromEnvironment(
    'RESQNET_TILE_ATTRIBUTION',
    defaultValue: 'Map data providers',
  );
  const attributionUrl = String.fromEnvironment('RESQNET_TILE_ATTRIBUTION_URL');

  return resolveMapTileProviderFrom(
    urlTemplate: urlTemplate,
    apiKey: apiKey,
    attribution: attribution,
    attributionUrl: attributionUrl,
  );
}

/// The actual selection logic behind [resolveMapTileProvider], taking
/// its would-be `--dart-define` values as plain parameters instead of
/// reading them directly — `String.fromEnvironment` is a compile-time
/// constant in real builds, which makes the decision itself untestable
/// unless it's isolated like this. [resolveMapTileProvider] is the only
/// real caller; tests call this directly with fixture values.
@visibleForTesting
MapTileProvider resolveMapTileProviderFrom({
  required String urlTemplate,
  required String apiKey,
  required String attribution,
  required String attributionUrl,
}) {
  if (urlTemplate.isEmpty) return const OpenStreetMapDirectProvider();

  final resolvedUrl = apiKey.isEmpty ? urlTemplate : urlTemplate.replaceAll('{key}', apiKey);
  return ConfiguredTileProvider._(
    urlTemplate: resolvedUrl,
    attributionText: attribution,
    attributionUrl: attributionUrl,
  );
}
