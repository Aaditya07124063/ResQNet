import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/hazard_service.dart';
import '../../core/services/map/map_tile_provider.dart';
import '../../core/services/map/offline_map_region_store.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/safe_zone_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  Position? _currentPosition;
  bool _isOffline = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  bool _isMarkingRoute = false;
  final List<LatLng> _routeDraftPoints = [];

  // ONE source of truth for the tile URL/attribution — see
  // core/services/map/map_tile_provider.dart's own doc comment. This used
  // to be a separately-hardcoded constant here AND in map_cache_service.dart.
  final MapTileProvider _tileProvider = resolveMapTileProvider();

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _getLocation();
    OfflineMapRegionStore.instance.ensureRenderStoreReady();
  }

  Future<void> _checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup('tile.openstreetmap.org')
          .timeout(const Duration(seconds: 3));
      setState(() => _isOffline = result.isEmpty || result[0].rawAddress.isEmpty);
    } catch (_) {
      setState(() => _isOffline = true);
    }
  }

  Future<void> _getLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 8));
      setState(() => _currentPosition = pos);
      _mapController.move(LatLng(pos.latitude, pos.longitude), 14);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        setState(() => _currentPosition = last);
        _mapController.move(LatLng(last.latitude, last.longitude), 14);
      }
    }
  }

  Future<void> _downloadCurrentArea() async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for GPS location...')),
      );
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
    });

    try {
      final center =
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude);

      // Download tiles within 25 km radius, zoom 10–16
      const regionRadiusKm = 25.0;
      final downloadable = CircleRegion(center, regionRadiusKm).toDownloadable(
        minZoom: 10,
        maxZoom: 16,
        options: TileLayer(
          urlTemplate: _tileProvider.urlTemplate,
          userAgentPackageName: _tileProvider.userAgentPackageName,
        ),
      );

      // Each downloaded area gets its OWN independent FMTC store (see
      // OfflineMapRegionStore's doc comment) so it can later be deleted
      // on its own without affecting any other downloaded region — this
      // device may have several overlapping or disjoint regions at once.
      final regionId = await OfflineMapRegionStore.instance.beginRegion();
      final store = FMTCStore(OfflineMapRegionStore.regionStoreName(regionId));
      final progressStream = store.download.startForeground(
        region: downloadable,
        parallelThreads: 5,
        maxBufferLength: 200,
        skipExistingTiles: true,
        skipSeaTiles: true,
      );

      await for (final event in progressStream) {
        if (mounted) {
          setState(() => _downloadProgress = event.percentageProgress / 100);
        }
      }

      // Phase J region bookkeeping — best-effort; a failure here must not
      // undo the successful tile download above or block the success
      // message the user is waiting for.
      try {
        await OfflineMapRegionStore.instance.recordDownloadedRegion(
          id: regionId,
          label: 'Downloaded area',
          center: center,
          radiusKm: regionRadiusKm,
        );
      } catch (_) {
        // Non-fatal.
      }

      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Map downloaded! Works offline now.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
    }
  }

  /// Lists every downloaded offline region with its own delete action —
  /// the real, reachable UI for the per-region independence
  /// OfflineMapRegionStore provides (deleting one region here never
  /// touches any other region's own tiles).
  Future<void> _showManageRegionsSheet() async {
    final regions = await OfflineMapRegionStore.instance.listRegions();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          Future<void> refresh() async {
            final next = await OfflineMapRegionStore.instance.listRegions();
            setSheetState(() => regions
              ..clear()
              ..addAll(next));
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Offline map regions', style: Theme.of(sheetContext).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  FutureBuilder<double>(
                    future: OfflineMapRegionStore.instance.totalSizeKib(),
                    builder: (_, snap) => Text(
                      snap.hasData ? 'Total storage used: ${(snap.data! / 1024).toStringAsFixed(1)} MB' : 'Total storage used: …',
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (regions.isEmpty) const Text('No offline regions downloaded yet.'),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: regions.length,
                      itemBuilder: (_, i) {
                        final region = regions[i];
                        return FutureBuilder<bool>(
                          future: OfflineMapRegionStore.instance.isRegionHealthy(region),
                          builder: (_, healthSnap) {
                            final healthy = healthSnap.data;
                            return ListTile(
                              leading: Icon(
                                healthy == null
                                    ? Icons.hourglass_empty
                                    : healthy
                                        ? Icons.map
                                        : Icons.error_outline,
                                color: healthy == false ? Colors.orange : null,
                              ),
                              title: Text(region.label),
                              subtitle: Text(
                                '${region.radiusKm.toStringAsFixed(0)} km radius • ${region.tileCountAtDownload} tiles'
                                '${healthy == false ? ' • corrupted/incomplete' : ''}',
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete this region only',
                                onPressed: () async {
                                  await OfflineMapRegionStore.instance.deleteRegion(region.id);
                                  await refresh();
                                },
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (regions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_forever),
                      label: const Text('Clear all offline regions'),
                      onPressed: () async {
                        await OfflineMapRegionStore.instance.deleteAllRegionsAndTiles();
                        await refresh();
                      },
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// "320 m • NE" — works from raw GPS coordinates alone, so it still tells
  /// you where to head even when no map tiles are available at all.
  String? _distanceBearingText(double lat, double lng) {
    if (_currentPosition == null) return null;
    final distance = Geolocator.distanceBetween(
        _currentPosition!.latitude, _currentPosition!.longitude, lat, lng);
    final bearing = Geolocator.bearingBetween(
        _currentPosition!.latitude, _currentPosition!.longitude, lat, lng);
    final distText = distance >= 1000
        ? '${(distance / 1000).toStringAsFixed(1)} km'
        : '${distance.toStringAsFixed(0)} m';
    return '$distText • ${_compassDirection(bearing)}';
  }

  String _compassDirection(double bearing) {
    const dirs = [
      'N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW',
    ];
    final normalized = (bearing + 360) % 360;
    final idx = ((normalized + 22.5) / 45).floor() % 8;
    return dirs[idx];
  }

  @override
  Widget build(BuildContext context) {
    final meshService = context.watch<MeshService>();
    final hazardService = context.watch<HazardService>();
    final safeZoneService = context.watch<SafeZoneService>();

    // Hazard/safe-zone/safe-route reports travel as mesh messages too (so
    // they relay offline), but their services already decode and expose
    // them separately below — exclude the raw payloads here or they'd show
    // up twice.
    final locatedMessages = meshService.messages
        .where((m) =>
            m.latitude != null &&
            m.longitude != null &&
            !m.message.startsWith(HazardService.hazardPrefix) &&
            !m.message.startsWith(SafeZoneService.zonePrefix) &&
            !m.message.startsWith(SafeZoneService.routePrefix))
        .toList();

    // Everything worth finding on this screen, sorted nearest-first, so the
    // list underneath the map is useful even when the map itself is blank
    // (no cached tiles + no internet).
    final nearby = <_NearbyItem>[
      ...locatedMessages.map((m) => _NearbyItem(
            title: m.senderName,
            subtitle: m.message,
            latitude: m.latitude!,
            longitude: m.longitude!,
            icon: Icons.warning_amber_rounded,
            color: Colors.red,
          )),
      ...hazardService.hazards.map((h) => _NearbyItem(
            title: h.typeLabel,
            subtitle: h.description.isNotEmpty ? h.description : h.reporter,
            latitude: h.latitude,
            longitude: h.longitude,
            icon: h.icon,
            color: h.color,
          )),
      ...safeZoneService.zones.map((z) => _NearbyItem(
            title: z.name,
            subtitle: 'Safe zone',
            latitude: z.latitude,
            longitude: z.longitude,
            icon: z.icon,
            color: Colors.green,
          )),
    ];
    if (_currentPosition != null) {
      nearby.sort((a, b) => Geolocator.distanceBetween(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            a.latitude,
            a.longitude,
          ).compareTo(Geolocator.distanceBetween(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            b.latitude,
            b.longitude,
          )));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isMarkingRoute ? 'Tap points along the safe route' : 'Offline Map'),
        actions: [
          if (!_isMarkingRoute) ...[
            IconButton(
              icon: const Icon(Icons.report),
              tooltip: 'Report a hazard',
              onPressed: _reportHazard,
            ),
            IconButton(
              icon: const Icon(Icons.add_location_alt),
              tooltip: 'Mark a safe zone',
              onPressed: _addSafeZoneAtCurrentPosition,
            ),
            IconButton(
              icon: const Icon(Icons.alt_route),
              tooltip: 'Mark a safe route',
              onPressed: () => setState(() {
                _isMarkingRoute = true;
                _routeDraftPoints.clear();
              }),
            ),
            if (!_isDownloading)
              IconButton(
                icon: const Icon(Icons.download_for_offline),
                tooltip: 'Download area for offline use',
                onPressed: _downloadCurrentArea,
              ),
            IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Manage offline maps',
              onPressed: _showManageRegionsSheet,
            ),
          ] else ...[
            TextButton(
              onPressed: () => setState(() {
                _isMarkingRoute = false;
                _routeDraftPoints.clear();
              }),
              child: const Text('Cancel', style: TextStyle(color: Colors.white)),
            ),
            TextButton(
              onPressed: _routeDraftPoints.length >= 2 ? _finishSafeRoute : null,
              child: Text('Done (${_routeDraftPoints.length})',
                  style: TextStyle(
                      color: _routeDraftPoints.length >= 2
                          ? Colors.white
                          : Colors.white38)),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentPosition != null
                        ? LatLng(_currentPosition!.latitude,
                            _currentPosition!.longitude)
                        : const LatLng(28.6, 77.2), // Default: New Delhi
                    initialZoom: 13,
                    onTap: _isMarkingRoute
                        ? (tapPos, point) =>
                            setState(() => _routeDraftPoints.add(point))
                        : null,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _tileProvider.urlTemplate,
                      userAgentPackageName: _tileProvider.userAgentPackageName,
                      maxNativeZoom: _tileProvider.maxZoom,
                      // Bound to renderStoreName only as an anchor — it
                      // never holds region tiles itself.
                      // fallbackToAlternativeStore (true by default)
                      // means a miss here transparently checks every
                      // per-region store too, so tiles from every
                      // downloaded region render here at once, while
                      // each stays independently deletable. See
                      // OfflineMapRegionStore's doc comment.
                      tileProvider: const FMTCStore(OfflineMapRegionStore.renderStoreName).getTileProvider(
                        settings: FMTCTileProviderSettings(
                          behavior: CacheBehavior.cacheFirst,
                          fallbackToAlternativeStore: true,
                        ),
                      ),
                    ),

                    // Safe routes ("this way is safe" — peer-marked or from
                    // an official feed), plus the route currently being drawn.
                    PolylineLayer(
                      polylines: [
                        ...safeZoneService.routes.map(
                          (r) => Polyline(
                            points: r.points,
                            strokeWidth: 5,
                            color: Colors.green,
                          ),
                        ),
                        if (_routeDraftPoints.length >= 2)
                          Polyline(
                            points: _routeDraftPoints,
                            strokeWidth: 5,
                            color: Colors.green.withOpacity(0.5),
                          ),
                      ],
                    ),

                    // Markers
                    MarkerLayer(
                      markers: [
                        // Current location
                        if (_currentPosition != null)
                          Marker(
                            point: LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            ),
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.my_location,
                              color: Colors.blue,
                              size: 36,
                            ),
                          ),

                        // SOS messages from mesh
                        ...locatedMessages.map(
                          (m) => Marker(
                            point: LatLng(m.latitude!, m.longitude!),
                            width: 40,
                            height: 40,
                            child: GestureDetector(
                              onTap: () => _showMessagePopup(
                                  m.message, m.senderName, m.latitude!, m.longitude!),
                              child: const Icon(
                                Icons.warning_amber_rounded,
                                color: Colors.red,
                                size: 36,
                              ),
                            ),
                          ),
                        ),

                        // Hazards (flood, fire, etc. — peer-reported or from
                        // an official feed)
                        ...hazardService.hazards.map(
                          (h) => Marker(
                            point: LatLng(h.latitude, h.longitude),
                            width: 40,
                            height: 40,
                            child: GestureDetector(
                              onTap: () => _showMessagePopup(
                                  '${h.typeLabel}${h.description.isNotEmpty ? ': ${h.description}' : ''}',
                                  h.reporter,
                                  h.latitude,
                                  h.longitude),
                              child: Icon(h.icon, color: h.color, size: 36),
                            ),
                          ),
                        ),

                        // Safe zones (shelters, hospitals, high ground —
                        // peer-marked or from an official feed)
                        ...safeZoneService.zones.map(
                          (z) => Marker(
                            point: LatLng(z.latitude, z.longitude),
                            width: 40,
                            height: 40,
                            child: GestureDetector(
                              onTap: () => _showMessagePopup(
                                  'Safe zone', z.name, z.latitude, z.longitude),
                              child: Icon(z.icon, color: Colors.green, size: 36),
                            ),
                          ),
                        ),

                        // Points tapped so far while drawing a safe route
                        ..._routeDraftPoints.map(
                          (p) => Marker(
                            point: p,
                            width: 16,
                            height: 16,
                            child: const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.green,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    // Required tile attribution (Phase I) — was previously
                    // missing entirely, a real compliance gap independent
                    // of which tile provider is active.
                    RichAttributionWidget(
                      attributions: [
                        TextSourceAttribution(
                          _tileProvider.attributionText,
                          onTap: _tileProvider.attributionUrl.isEmpty
                              ? null
                              : () => launchUrl(Uri.parse(_tileProvider.attributionUrl)),
                        ),
                      ],
                    ),
                  ],
                ),

                // Offline banner
                if (_isOffline)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      color: Colors.orange.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.wifi_off, color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Offline — showing cached tiles. Use the list below if the map is blank.',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Tile provider configuration state (item 3's explicit,
                // non-silent surfacing of MapTileProvider.isProductionReady
                // — a developer/tester must see this, not just find it by
                // reading source). Never shown once a real, configured
                // provider (RESQNET_TILE_URL_TEMPLATE) is supplied.
                if (!_tileProvider.isProductionReady)
                  Positioned(
                    top: _isOffline ? 28 : 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      color: Colors.blueGrey.shade800,
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.construction, color: Colors.white, size: 14),
                          SizedBox(width: 6),
                          Text(
                            'Development map tiles — not configured for production distribution',
                            style: TextStyle(color: Colors.white, fontSize: 11),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),

                // Download progress card
                if (_isDownloading)
                  Positioned(
                    bottom: 20,
                    left: 20,
                    right: 20,
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(blurRadius: 8, color: Colors.black26),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Downloading map for offline use...'),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: _downloadProgress),
                          const SizedBox(height: 4),
                          Text('${(_downloadProgress * 100).toStringAsFixed(0)}%'),
                        ],
                      ),
                    ),
                  ),

                Positioned(
                  bottom: 20,
                  right: 20,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _getLocation,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),

          // Always-available list: works with zero map tiles, since it's
          // built from raw coordinates, not the visual map.
          if (nearby.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                border: Border(
                    top: BorderSide(color: Colors.grey.shade800, width: 1)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        const Icon(Icons.list, size: 16),
                        const SizedBox(width: 6),
                        Text('Nearby (${nearby.length})',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: nearby.length,
                      itemBuilder: (_, i) {
                        final item = nearby[i];
                        final distText = _distanceBearingText(
                            item.latitude, item.longitude);
                        return ListTile(
                          dense: true,
                          leading: Icon(item.icon, color: item.color),
                          title: Text(item.title,
                              style: const TextStyle(fontSize: 13)),
                          subtitle: Text(item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)),
                          trailing: distText != null
                              ? Text(distText,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold))
                              : null,
                          onTap: () {
                            _mapController.move(
                                LatLng(item.latitude, item.longitude), 15);
                            _showMessagePopup(item.subtitle, item.title,
                                item.latitude, item.longitude);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showMessagePopup(
      String message, String sender, double lat, double lng) {
    final distText = _distanceBearingText(lat, lng);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sender,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            Text(message),
            if (distText != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.navigation, size: 18, color: Colors.blue),
                  const SizedBox(width: 6),
                  Text(distText,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.blue)),
                  const SizedBox(width: 6),
                  const Text('from you',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _reportHazard() async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for GPS location...')),
      );
      return;
    }

    String selectedType = 'flood';
    final descController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Report a Hazard'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<String>(
                value: selectedType,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'flood', child: Text('Flooded Area')),
                  DropdownMenuItem(value: 'fire', child: Text('Fire')),
                  DropdownMenuItem(
                      value: 'powerline', child: Text('Downed Powerline')),
                  DropdownMenuItem(
                      value: 'landslide', child: Text('Landslide')),
                  DropdownMenuItem(
                      value: 'road_blocked', child: Text('Road Blocked')),
                  DropdownMenuItem(value: 'other', child: Text('Other')),
                ],
                onChanged: (v) =>
                    setDialogState(() => selectedType = v ?? 'flood'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                    hintText: 'Description (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Report'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final hazardService = context.read<HazardService>();
    final meshService = context.read<MeshService>();
    final msg = hazardService.createHazard(
      type: selectedType,
      description: descController.text.trim(),
      latitude: _currentPosition!.latitude,
      longitude: _currentPosition!.longitude,
      reporter: 'Nearby user',
    );
    meshService.broadcastMessage(msg);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hazard reported and broadcast.')),
      );
    }
  }

  Future<void> _addSafeZoneAtCurrentPosition() async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for GPS location...')),
      );
      return;
    }

    String selectedType = 'shelter';
    final nameController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Mark a Safe Zone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(hintText: 'Name (e.g. Community Hall)'),
              ),
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: selectedType,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'shelter', child: Text('Shelter')),
                  DropdownMenuItem(value: 'hospital', child: Text('Hospital')),
                  DropdownMenuItem(value: 'school', child: Text('School')),
                  DropdownMenuItem(
                      value: 'high_ground', child: Text('High Ground')),
                  DropdownMenuItem(value: 'home', child: Text('Home')),
                ],
                onChanged: (v) =>
                    setDialogState(() => selectedType = v ?? 'shelter'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Mark Safe'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;

    final safeZoneService = context.read<SafeZoneService>();
    final meshService = context.read<MeshService>();
    final zone = SafeZone(
      id: const Uuid().v4(),
      name: nameController.text.trim(),
      latitude: _currentPosition!.latitude,
      longitude: _currentPosition!.longitude,
      type: selectedType,
    );
    await safeZoneService.addZone(zone);
    meshService.broadcastMessage(safeZoneService.createZoneBroadcast(zone));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Safe zone marked and broadcast.')),
      );
    }
  }

  Future<void> _finishSafeRoute() async {
    if (_routeDraftPoints.length < 2) return;

    String selectedHazard = 'landslide';
    final nameController = TextEditingController();
    final descController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Mark This Route Safe'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                decoration:
                    const InputDecoration(hintText: 'Route name (e.g. Main Rd to shelter)'),
              ),
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: selectedHazard,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'landslide', child: Text('Safe from Landslide')),
                  DropdownMenuItem(value: 'flood', child: Text('Safe from Flood')),
                  DropdownMenuItem(value: 'fire', child: Text('Safe from Fire')),
                  DropdownMenuItem(value: 'general', child: Text('Generally Clear')),
                ],
                onChanged: (v) =>
                    setDialogState(() => selectedHazard = v ?? 'landslide'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(hintText: 'Description (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Broadcast'),
            ),
          ],
        ),
      ),
    );

    if (!mounted) return;
    if (confirmed != true) {
      setState(() {
        _isMarkingRoute = false;
        _routeDraftPoints.clear();
      });
      return;
    }

    final safeZoneService = context.read<SafeZoneService>();
    final meshService = context.read<MeshService>();
    final msg = safeZoneService.createRoute(
      name: nameController.text.trim(),
      description: descController.text.trim(),
      safeFrom: selectedHazard,
      points: List.of(_routeDraftPoints),
      source: 'Nearby user',
    );
    meshService.broadcastMessage(msg);

    setState(() {
      _isMarkingRoute = false;
      _routeDraftPoints.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Safe route marked and broadcast.')),
      );
    }
  }
}

class _NearbyItem {
  final String title;
  final String subtitle;
  final double latitude;
  final double longitude;
  final IconData icon;
  final Color color;

  _NearbyItem({
    required this.title,
    required this.subtitle,
    required this.latitude,
    required this.longitude,
    required this.icon,
    required this.color,
  });
}
