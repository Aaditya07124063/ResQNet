import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/message_priority.dart';

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationService>();
    final mesh = context.watch<MeshService>();
    final pos = location.currentPosition;
    final center = pos != null
        ? LatLng(pos.latitude, pos.longitude)
        : const LatLng(20.5937, 78.9629);

    final markers = <Marker>[];
    if (pos != null) {
      markers.add(Marker(
        point: center,
        width: 40,
        height: 40,
        child: const Icon(Icons.my_location, color: AppColors.infoBlue, size: 36),
      ));
    }
    for (final m in mesh.messages) {
      if (m.latitude != null && m.longitude != null) {
        markers.add(Marker(
          point: LatLng(m.latitude!, m.longitude!),
          width: 36,
          height: 36,
          child: Icon(Icons.location_pin,
              color: priorityColor(m.priority), size: 36),
        ));
      }
    }

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Emergency Map',
            style: TextStyle(color: Colors.white)),
      ),
      body: FlutterMap(
        options: MapOptions(initialCenter: center, initialZoom: 13),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.resqnet.app',
          ),
          MarkerLayer(markers: markers),
        ],
      ),
    );
  }
}
