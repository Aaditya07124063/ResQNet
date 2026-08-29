import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/services/hazard_service.dart';
import '../../core/services/mesh_service.dart';

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

  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _getLocation();
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
      final downloadable = CircleRegion(center, 25).toDownloadable(
        minZoom: 10,
        maxZoom: 16,
        options: TileLayer(
          urlTemplate: _tileUrl,
          userAgentPackageName: 'com.resqnet.app',
        ),
      );

      final progressStream =
          const FMTCStore('mapStore').download.startForeground(
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

    // Hazard reports travel as mesh messages too (so they relay offline),
    // but HazardService already decodes and exposes them separately below —
    // exclude the raw payload here or every hazard would show up twice.
    final locatedMessages = meshService.messages
        .where((m) =>
            m.latitude != null &&
            m.longitude != null &&
            !m.message.startsWith(HazardService.hazardPrefix))
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
        title: const Text('Offline Map'),
        actions: [
          IconButton(
            icon: const Icon(Icons.report),
            tooltip: 'Report a hazard',
            onPressed: _reportHazard,
          ),
          if (!_isDownloading)
            IconButton(
              icon: const Icon(Icons.download_for_offline),
              tooltip: 'Download area for offline use',
              onPressed: _downloadCurrentArea,
            ),
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
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: _tileUrl,
                      userAgentPackageName: 'com.resqnet.app',
                      tileProvider: const FMTCStore('mapStore').getTileProvider(
                        settings: FMTCTileProviderSettings(
                          behavior: CacheBehavior.cacheFirst,
                        ),
                      ),
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
