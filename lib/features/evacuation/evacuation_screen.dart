import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/safe_zone_service.dart';

class EvacuationScreen extends StatefulWidget {
  const EvacuationScreen({super.key});

  @override
  State<EvacuationScreen> createState() => _EvacuationScreenState();
}

class _EvacuationScreenState extends State<EvacuationScreen> {
  final MapController _mapController = MapController();
  Position? _position;
  StreamSubscription<Position>? _posSub;

  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  @override
  void initState() {
    super.initState();
    context.read<SafeZoneService>().load();
    _startTracking();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _startTracking() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() => _position = pos);
        _mapController.move(LatLng(pos.latitude, pos.longitude), 14);
      }
    } catch (_) {}

    // Live position updates every 10 meters
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
  }

  void _addZoneDialog(LatLng point) {
    final nameController = TextEditingController();
    String type = 'shelter';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Safe Zone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Name (e.g. Village School)',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'shelter', child: Text('🏕 Shelter')),
                  DropdownMenuItem(value: 'home', child: Text('🏠 Home')),
                  DropdownMenuItem(
                      value: 'hospital', child: Text('🏥 Hospital')),
                  DropdownMenuItem(value: 'school', child: Text('🏫 School')),
                  DropdownMenuItem(
                      value: 'high_ground', child: Text('⛰ High Ground')),
                ],
                onChanged: (v) => setDialogState(() => type = v ?? 'shelter'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (nameController.text.trim().isEmpty) return;
                context.read<SafeZoneService>().addZone(SafeZone(
                      id: const Uuid().v4(),
                      name: nameController.text.trim(),
                      latitude: point.latitude,
                      longitude: point.longitude,
                      type: type,
                    ));
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final zoneService = context.watch<SafeZoneService>();
    final current = _position != null
        ? LatLng(_position!.latitude, _position!.longitude)
        : null;
    final nearest = current != null ? zoneService.nearestZone(current) : null;
    final distKm = (current != null && nearest != null)
        ? SafeZoneService.distanceKm(
            current, LatLng(nearest.latitude, nearest.longitude))
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Evacuation Navigator')),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: current ?? const LatLng(28.6, 77.2),
              initialZoom: 13,
              onLongPress: (_, point) => _addZoneDialog(point),
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

              // Route line to nearest safe zone
              if (current != null && nearest != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [
                        current,
                        LatLng(nearest.latitude, nearest.longitude),
                      ],
                      strokeWidth: 4,
                      color: Colors.green,
                    ),
                  ],
                ),

              MarkerLayer(
                markers: [
                  if (current != null)
                    Marker(
                      point: current,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.my_location,
                          color: Colors.blue, size: 34),
                    ),
                  ...zoneService.zones.map(
                    (z) => Marker(
                      point: LatLng(z.latitude, z.longitude),
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onLongPress: () => _confirmDelete(z),
                        child: Icon(
                          z.icon,
                          color: z.id == nearest?.id
                              ? Colors.green
                              : Colors.orange,
                          size: 36,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Nearest zone info card
          if (nearest != null && distKm != null)
            Positioned(
              top: 12,
              left: 12,
              right: 12,
              child: Card(
                color: Colors.green.shade700,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(nearest.icon, color: Colors.white, size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Nearest: ${nearest.name}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold),
                            ),
                            Text(
                              distKm < 1
                                  ? '${(distKm * 1000).toStringAsFixed(0)} m away'
                                  : '${distKm.toStringAsFixed(1)} km away',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.center_focus_strong,
                            color: Colors.white),
                        onPressed: () => _mapController.move(
                          LatLng(nearest.latitude, nearest.longitude),
                          15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Empty state hint
          if (zoneService.zones.isEmpty)
            Positioned(
              bottom: 30,
              left: 20,
              right: 20,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      const Icon(Icons.touch_app, color: Colors.orange),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Long-press anywhere on the map to add a Safe Zone (home, school, hospital, high ground)',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: current == null
            ? null
            : () => _addZoneDialog(current),
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add Here'),
      ),
    );
  }

  void _confirmDelete(SafeZone zone) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${zone.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<SafeZoneService>().removeZone(zone.id);
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}