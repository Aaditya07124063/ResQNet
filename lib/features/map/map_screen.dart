import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
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
      final pos = await Geolocator.getCurrentPosition();
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

  @override
  Widget build(BuildContext context) {
    final meshService = context.watch<MeshService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Map'),
        actions: [
          if (!_isDownloading)
            IconButton(
              icon: const Icon(Icons.download_for_offline),
              tooltip: 'Download area for offline use',
              onPressed: _downloadCurrentArea,
            ),
        ],
      ),
      body: Stack(
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
                  ...meshService.messages
                      .where((m) => m.latitude != null && m.longitude != null)
                      .map(
                        (m) => Marker(
                          point: LatLng(m.latitude!, m.longitude!),
                          width: 40,
                          height: 40,
                          child: GestureDetector(
                            onTap: () =>
                                _showMessagePopup(m.message, m.senderId),
                            child: const Icon(
                              Icons.warning_amber_rounded,
                              color: Colors.red,
                              size: 36,
                            ),
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
                      'Offline mode — showing downloaded tiles',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),

          // Download progress card
          if (_isDownloading)
            Positioned(
              bottom: 80,
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
        ],
      ),
      floatingActionButton: FloatingActionButton(
        mini: true,
        onPressed: _getLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }

  void _showMessagePopup(String message, String sender) {
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
          ],
        ),
      ),
    );
  }
}