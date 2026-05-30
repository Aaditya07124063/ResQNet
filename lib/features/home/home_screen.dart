import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/location_service.dart';
import '../../core/utils/permission_handler.dart';
import '../../widgets/sos_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _init();
  }

 Future<void> _init() async {
    await requestAllPermissions();
    if (!mounted) return;
    final mesh = context.read<MeshService>();
    final location = context.read<LocationService>();
    mesh.start('ResQNet User');
    location.getCurrentPosition();
}

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final location = context.watch<LocationService>();
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('ResQNet',
            style: TextStyle(
                color: AppColors.emergencyRed,
                fontWeight: FontWeight.bold,
                fontSize: 22)),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart, color: Colors.white),
            onPressed: () => Navigator.pushNamed(context, AppRoutes.dashboard),
          ),
        ],
      ),
      body: Column(children: [
        Container(
          color: AppColors.surfaceDark,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _statusChip(Icons.devices, '${mesh.connectedCount} Devices',
                mesh.connectedCount > 0 ? AppColors.safeGreen : AppColors.lowGrey),
            _statusChip(
                Icons.location_on,
                location.currentPosition != null ? 'GPS Active' : 'No GPS',
                location.currentPosition != null
                    ? AppColors.safeGreen
                    : AppColors.warningAmber),
            _statusChip(Icons.wifi_tethering,
                mesh.isRunning ? 'Mesh ON' : 'Mesh OFF',
                mesh.isRunning ? AppColors.safeGreen : AppColors.lowGrey),
          ]),
        ),
        Expanded(
          child: Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('EMERGENCY?',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 16,
                      letterSpacing: 2)),
              const SizedBox(height: 8),
              const Text('TAP TO BROADCAST SOS',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 12)),
              const SizedBox(height: 32),
              SosButton(
                  onPressed: () => Navigator.pushNamed(context, AppRoutes.sos)),
              const SizedBox(height: 48),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _actionBtn(Icons.message, 'Message',
                    () => Navigator.pushNamed(context, AppRoutes.mesh)),
                const SizedBox(width: 16),
                _actionBtn(Icons.map, 'Map',
                    () => Navigator.pushNamed(context, AppRoutes.map)),
                const SizedBox(width: 16),
                _actionBtn(Icons.bluetooth_searching, 'Devices',
                    () => Navigator.pushNamed(context, AppRoutes.mesh)),
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _statusChip(IconData icon, String label, Color color) =>
      Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ]);

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Icon(icon, color: AppColors.emergencyRed, size: 28),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 12)),
          ]),
        ),
      );
}
