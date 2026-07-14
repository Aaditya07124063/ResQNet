import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/services/hazard_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/profile_service.dart';

class HazardMapScreen extends StatefulWidget {
  const HazardMapScreen({super.key});

  @override
  State<HazardMapScreen> createState() => _HazardMapScreenState();
}

class _HazardMapScreenState extends State<HazardMapScreen> {
  final MapController _mapController = MapController();
  Position? _position;

  static const String _tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const List<Map<String, dynamic>> _hazardTypes = [
    {'type': 'flood', 'label': '🌊 Flooded Area'},
    {'type': 'fire', 'label': '🔥 Fire'},
    {'type': 'powerline', 'label': '⚡ Downed Powerline'},
    {'type': 'landslide', 'label': '⛰ Landslide'},
    {'type': 'road_blocked', 'label': '🚧 Road Blocked'},
    {'type': 'other', 'label': '⚠️ Other Hazard'},
  ];

  @override
  void initState() {
    super.initState();
    context.read<HazardService>().load();
    _getLocation();
  }

  Future<void> _getLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() => _position = pos);
        _mapController.move(LatLng(pos.latitude, pos.longitude), 14);
      }
    } catch (_) {}
  }

  void _reportHazardDialog(LatLng point) {
    String selectedType = 'flood';
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Report Hazard'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: const InputDecoration(labelText: 'Hazard type'),
                items: _hazardTypes
                    .map((h) => DropdownMenuItem(
                          value: h['type'] as String,
                          child: Text(h['label'] as String),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setDialogState(() => selectedType = v ?? 'flood'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'e.g. Water above knee level',
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.campaign),
              label: const Text('Report'),
              onPressed: () {
                final profile = context.read<ProfileService>();
                final meshMessage =
                    context.read<HazardService>().createHazard(
                          type: selectedType,
                          description: descController.text.trim(),
                          latitude: point.latitude,
                          longitude: point.longitude,
                          reporter: profile.name.isNotEmpty
                              ? profile.name
                              : 'Anonymous',
                        );
                // Broadcast to all nearby devices over mesh
                context.read<MeshService>().broadcastMessage(meshMessage);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content:
                        Text('⚠️ Hazard reported — broadcast to nearby devices'),
                    backgroundColor: Colors.orange,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showHazardDetails(Hazard h) {
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
            Row(
              children: [
                Icon(h.icon, color: h.color, size: 30),
                const SizedBox(width: 10),
                Text(h.typeLabel,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            if (h.description.isNotEmpty) ...[
              Text(h.description),
              const SizedBox(height: 8),
            ],
            Text('Reported by: ${h.reporter}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            Text(
              '${DateTime.now().difference(h.timestamp).inMinutes} minutes ago',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Remove',
                    style: TextStyle(color: Colors.red)),
                onPressed: () {
                  context.read<HazardService>().removeHazard(h.id);
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hazardService = context.watch<HazardService>();
    final mesh = context.watch<MeshService>();

    // Absorb any hazards that arrived over the mesh
    WidgetsBinding.instance.addPostFrameCallback((_) {
      hazardService.syncFromMesh(mesh.messages);
    });

    final current = _position != null
        ? LatLng(_position!.latitude, _position!.longitude)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hazard Map'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                '${hazardService.hazards.length} active',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: current ?? const LatLng(28.6, 77.2),
              initialZoom: 13,
              onLongPress: (_, point) => _reportHazardDialog(point),
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
                  ...hazardService.hazards.map(
                    (h) => Marker(
                      point: LatLng(h.latitude, h.longitude),
                      width: 44,
                      height: 44,
                      child: GestureDetector(
                        onTap: () => _showHazardDetails(h),
                        child: Container(
                          decoration: BoxDecoration(
                            color: h.color.withOpacity(0.2),
                            shape: BoxShape.circle,
                            border: Border.all(color: h.color, width: 2),
                          ),
                          child: Icon(h.icon, color: h.color, size: 26),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Hint card
          if (hazardService.hazards.isEmpty)
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
                          'Long-press on the map to report a hazard. It broadcasts to all nearby ResQNet users — no internet needed.',
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
        backgroundColor: Colors.orange,
        onPressed: current == null ? null : () => _reportHazardDialog(current),
        icon: const Icon(Icons.add_alert),
        label: const Text('Report Here'),
      ),
    );
  }
}