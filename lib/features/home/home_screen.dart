import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_routes.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/check_in_service.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/location_log_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/notification_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/seismic_service.dart';
import '../../core/utils/permission_handler.dart' as perms;
import '../../features/profile/profile_screen.dart';
import '../../features/emergency_contacts/emergency_contacts_screen.dart';
import '../../features/sos_history/sos_history_screen.dart';
import '../check_in/check_in_screen.dart';
import '../crash_countdown/crash_countdown_dialog.dart';
import '../evacuation/evacuation_screen.dart';
import '../fake_call/fake_call_screen.dart';
import '../first_aid/first_aid_screen.dart';
import '../hazard_map/hazard_map_screen.dart';
import '../location_trail/location_trail_screen.dart';
import '../missing_person/missing_person_screen.dart';
import '../qr_profile/qr_profile_screen.dart';
import '../seismic/earthquake_alert_dialog.dart';
import '../../widgets/sos_button.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _crashDialogOpen = false;
  bool _quakeDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    await perms.requestAllPermissions();
    if (!mounted) return;
    NotificationService().initialize().catchError(
      (e) => debugPrint('Notification init error: $e'),
    );
    if (!mounted) return;
    context.read<LocationService>().getCurrentLocation();
    context.read<MeshService>().startMeshNetwork().catchError(
      (e) => debugPrint('Mesh start error: $e'),
    );

    // Location trail — saves GPS every 5 min for dead-phone recovery
    context.read<LocationLogService>().start();

    // Vehicle crash detection
    final crashService = context.read<CrashDetectionService>();
    crashService.start();
    crashService.addListener(() {
      if (crashService.crashDetected && mounted && !_crashDialogOpen) {
        _crashDialogOpen = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const CrashCountdownDialog(),
        ).then((_) => _crashDialogOpen = false);
      }
    });

    // Earthquake (seismic P-wave) detection
    final seismicService = context.read<SeismicService>();
    seismicService.start();
    seismicService.addListener(() {
      if (seismicService.quakeDetected && mounted && !_quakeDialogOpen) {
        _quakeDialogOpen = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const EarthquakeAlertDialog(),
        ).then((_) => _quakeDialogOpen = false);
      }
    });

    // Dead man's switch — check-in timer expired → auto SOS
    final checkInService = context.read<CheckInService>();
    checkInService.addListener(() {
      if (checkInService.expired && mounted) {
        checkInService.acknowledgeExpiry();
        checkInService.stop();
        _sendAutoSos(
          '⏱ CHECK-IN TIMER EXPIRED — user may need help. AUTO SOS.',
        );
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: Colors.red.shade900,
            title: const Text('⏱ Check-In Missed',
                style: TextStyle(color: Colors.white)),
            content: const Text(
              'Your safety check-in timer expired.\nAn SOS was broadcast automatically.',
              style: TextStyle(color: Colors.white70),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child:
                    const Text('OK', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    });
  }

  Future<void> _sendAutoSos(String text) async {
    final profile = context.read<ProfileService>();
    double? lat, lng;
    try {
      final pos = await Geolocator.getLastKnownPosition();
      lat = pos?.latitude;
      lng = pos?.longitude;
    } catch (_) {}
    if (!mounted) return;

    final name = profile.name.isNotEmpty ? profile.name : 'Unknown';
    final message = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: name,
      senderName: name,
      message:
          '$text\nBlood: ${profile.bloodGroup} | Allergies: ${profile.allergies}',
      type: EmergencyType.rescue,
      priority: PriorityLevel.critical,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );
    await context.read<MeshService>().broadcastMessage(message);
  }

  Future<void> _sendImSafe() async {
    HapticFeedback.mediumImpact();
    final profile = context.read<ProfileService>();
    double? lat, lng;
    try {
      final pos = await Geolocator.getLastKnownPosition();
      lat = pos?.latitude;
      lng = pos?.longitude;
    } catch (_) {}
    if (!mounted) return;

    final name = profile.name.isNotEmpty ? profile.name : 'Someone';
    final locText = (lat != null && lng != null)
        ? ' Location: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
        : '';

    final message = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: name,
      senderName: name,
      message: '✅ I AM SAFE — $name is safe.$locText',
      type: EmergencyType.general,
      priority: PriorityLevel.low,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );
    await context.read<MeshService>().broadcastMessage(message);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ "I am safe" broadcast to nearby devices'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final location = context.watch<LocationService>();
    final checkIn = context.watch<CheckInService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Row(
          children: [
            Icon(Icons.emergency, color: AppColors.emergencyRed, size: 24),
            SizedBox(width: 8),
            Text('ResQNet',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 20)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code,
                color: AppColors.textSecondary, size: 26),
            tooltip: 'My Emergency QR',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const QrProfileScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle,
                color: AppColors.textSecondary, size: 28),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ProfileScreen()),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Center(
              child: SosButton(
                isActive: false,
                onPressed: () => Navigator.pushNamed(context, AppRoutes.sos),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Tap to send SOS',
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _sendImSafe,
                icon: const Icon(Icons.check_circle,
                    color: AppColors.connectedGreen),
                label: const Text(
                  "I AM SAFE — tell everyone nearby",
                  style: TextStyle(
                      color: AppColors.connectedGreen,
                      fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.connectedGreen),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                _StatusChip(
                  label: '${mesh.connectedCount} Devices',
                  icon: Icons.wifi,
                  color: mesh.connectedCount > 0
                      ? AppColors.connectedGreen
                      : AppColors.textSecondary,
                  subtitle:
                      mesh.connectedCount > 0 ? 'Connected' : 'No peers',
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.mesh),
                ),
                const SizedBox(width: 8),
                _StatusChip(
                  label: location.currentPosition != null
                      ? 'GPS ON'
                      : 'GPS OFF',
                  icon: Icons.gps_fixed,
                  color: location.currentPosition != null
                      ? AppColors.connectedGreen
                      : AppColors.textSecondary,
                  subtitle: location.currentPosition != null
                      ? '${location.currentPosition!.latitude.toStringAsFixed(2)}, ${location.currentPosition!.longitude.toStringAsFixed(2)}'
                      : 'No signal',
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.map),
                ),
                const SizedBox(width: 8),
                _StatusChip(
                  label: mesh.isAdvertising ? 'Mesh ON' : 'Mesh OFF',
                  icon: Icons.hub,
                  color: mesh.isAdvertising
                      ? AppColors.connectedGreen
                      : AppColors.textSecondary,
                  subtitle: mesh.isDiscovering ? 'Scanning...' : 'Idle',
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.mesh),
                ),
              ],
            ),
            const SizedBox(height: 32),
            _ActionButton(
              icon: Icons.map,
              label: 'Emergency Map',
              subtitle: 'View alerts on map',
              color: AppColors.accentBlue,
              onTap: () => Navigator.pushNamed(context, AppRoutes.map),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.hub,
              label: 'Mesh Network',
              subtitle:
                  '${mesh.connectedCount} connected · ${mesh.discoveredDevices.length} nearby',
              color: AppColors.primaryOrange,
              onTap: () => Navigator.pushNamed(context, AppRoutes.mesh),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.dashboard,
              label: 'Dashboard',
              subtitle: '${mesh.messages.length} messages received',
              color: const Color(0xFF6A1B9A),
              onTap: () =>
                  Navigator.pushNamed(context, AppRoutes.dashboard),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.contact_phone,
              label: 'Emergency Contacts',
              subtitle: 'Call local emergency services',
              color: AppColors.emergencyRed,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const EmergencyContactsScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.medical_services,
              label: 'First Aid Guide',
              subtitle: 'CPR, snake bite, burns — 100% offline',
              color: AppColors.emergencyRed,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FirstAidScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.timer,
              label: 'Safety Check-In Timer',
              subtitle: checkIn.isActive
                  ? '⏱ Active — check in before time runs out'
                  : 'Auto-SOS if you go silent',
              color: checkIn.isActive
                  ? AppColors.connectedGreen
                  : AppColors.primaryOrange,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CheckInScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.qr_code,
              label: 'My Emergency QR',
              subtitle: 'Medical profile for paramedics — works offline',
              color: AppColors.connectedGreen,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const QrProfileScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.directions_run,
              label: 'Evacuation Navigator',
              subtitle: 'Route to nearest safe zone — offline',
              color: AppColors.connectedGreen,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EvacuationScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.warning_amber,
              label: 'Hazard Map',
              subtitle: 'Report & see local hazards — shared via mesh',
              color: AppColors.primaryOrange,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HazardMapScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.person_search,
              label: 'Missing Person',
              subtitle: 'Broadcast alerts over the mesh',
              color: AppColors.primaryOrange,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MissingPersonScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.phone_in_talk,
              label: 'Fake Call',
              subtitle: 'Escape unsafe situations discreetly',
              color: AppColors.accentBlue,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FakeCallScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.route,
              label: 'Location Trail',
              subtitle: 'Last 24h of locations saved on device',
              color: AppColors.accentBlue,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const LocationTrailScreen()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionButton(
              icon: Icons.history,
              label: 'SOS History',
              subtitle: 'View your past SOS alerts',
              color: AppColors.accentBlue,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SosHistoryScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _StatusChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          decoration: BoxDecoration(
            color: AppColors.cardDark,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 9),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}