import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/connectivity_status_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../../core/services/sos_service.dart';
import '../../core/utils/permission_handler.dart' as perms;
import '../home/widgets/sos_home_panel.dart';
import '../permissions/permissions_screen.dart';

/// SOS without an account, reachable from the sign-in screen. Uses the
/// same SOS panel as Home: the offline mesh and the SMS fallback need no
/// ResQNet account; only the server copy (and push alerts to trusted
/// contacts) needs one, and the status says so honestly.
class EmergencyAccessScreen extends StatefulWidget {
  const EmergencyAccessScreen({super.key});

  @override
  State<EmergencyAccessScreen> createState() => _EmergencyAccessScreenState();
}

class _EmergencyAccessScreenState extends State<EmergencyAccessScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    context.read<ConnectivityStatusService>().start();
    final mesh = context.read<MeshService>();
    final sos = context.read<SosService>();
    try {
      if (!await perms.permissionsExplained()) {
        if (!mounted) return;
        await showPermissionExplainer(context);
        await perms.markPermissionsExplained();
      }
      await perms.requestAllPermissions();
    } catch (e) {
      debugPrint('Permission request error: $e');
    }
    if (!mesh.isAdvertising && !mesh.isDiscovering) {
      await mesh.startMeshNetwork().catchError((Object e) => debugPrint('Mesh start error: $e'));
    }
    await SosDispatchService.resumeActive(sos, mesh).catchError((Object e) => debugPrint('Resume SOS failed: $e'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Emergency SOS', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const SosHomePanel(),
            const SizedBox(height: 16),
            Text(
              'You are not signed in. Your SOS still goes to nearby ResQNet devices over the offline mesh '
              'and opens an SMS to local helplines. Sign in to also alert your ResQNet trusted contacts.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
