# Offline maps and routing — current state and plan

## Current implementation (verified in code)

- **Rendering:** `flutter_map` (raster tiles) via `MapTileProvider` (`lib/core/services/map/map_tile_provider.dart`).
- **Default tile source:** `tile.openstreetmap.org` (`OpenStreetMapDirectProvider`, marked not production-ready).
- **Caching:** `flutter_map_tile_caching` (ObjectBox) — viewed tiles, plus per-region stores (`OfflineMapRegionStore`).
- **Overlays:** hazards, safe zones and hand-drawn "safe routes" from `HazardService` / `SafeZoneService`, shared over the mesh.
- **Routing:** none. There is no routing engine or road graph in the app.

## Licensing findings (checked against primary sources)

- **OSM tile server policy** (operations.osmfoundation.org/policies/tiles/, checked 2026-09-27): "Offline use is not permitted on `tile.openstreetmap.org`"; prefetch/bulk patterns "will be blocked without notice".
  - **Change made:** region download and automatic background prefetch are now disabled unless a licensed tile provider is configured (`allowsBulkDownload`).
  - Viewed tiles are still cached. The app still sends a distinct User-Agent (`com.resqnet.app`), as the policy requires.
- **OSM data** (Geofabrik Nepal extract, checked 2026-09-27): ODbL 1.0. The raw Nepal extract is 395 MB (`.osm.pbf`).
  - ODbL allows commercial and offline use with attribution ("© OpenStreetMap contributors") and share-alike for derived databases.

## Recommended offline map architecture (not yet implemented)

Base map plus a small emergency layer, as specified:

1. **Base map:** OSM-derived vector tiles for Nepal packaged as a single file (e.g. PMTiles or MBTiles), produced by ResQNet from the Geofabrik extract and hosted on ResQNet's own storage (MinIO) — no third-party tile server at runtime, no bulk traffic to OSM.
   - Packages: Nepal-wide, per province (7), and per district (77), plus a custom radius around the user.
   - Rendering needs a vector renderer (e.g. MapLibre GL via a Flutter plugin, or a vector-tile layer for `flutter_map`). Either choice must be evaluated for the current Flutter/Android/iOS toolchain before adoption.
2. **Alternative (faster, raster):** a licensed raster provider that explicitly permits offline caching. Configure via `ConfiguredTileProvider` (`--dart-define=RESQNET_TILE_URL_TEMPLATE=…`); the existing FMTC region download then works unchanged.
   - The provider's terms must allow offline storage; many commercial plans restrict it.
3. **Emergency layer:** small, frequently updated data served by the backend (SOS approximate locations for authorised users, official alerts, shelters, hospitals). Every item carries source, timestamp, status and expiry. This is kept separate from the base map.

## Offline routing — evaluation (no engine chosen yet)

Requirements: pedestrian and vehicle routing over Nepal roads and trails, offline on the phone, updateable.

| Option | Notes to verify before choosing |
|---|---|
| GraphHopper (Java, OSM) | Mature pedestrian/foot profiles and trail support; on-device use on Android is possible in principle. Check the licence of the version used and the Nepal graph size on disk. |
| Valhalla (C++, OSM) | Tiled routing graph suited to offline packages; supports pedestrian costing. Needs native builds for Android and iOS. Check the licence and the size of Nepal tiles. |
| OSRM (C++) | Fast, but server-oriented with large memory needs; poor fit for phones. |
| Server-side route precomputation | Only helps when online — does not meet the offline requirement. |

**Data:** OSM road and path coverage in rural Nepal varies. Trekking trails are mapped along major routes, but completeness must be sampled before any "offline route" is shown as trustworthy. Routes must always be labelled as computed from OSM data, possibly incomplete.

**Status: MISSING.** Nothing in the app computes a route today, and nothing should claim it does.
