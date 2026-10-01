import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/models/sos_alert.dart';
import '../../../core/services/connectivity_status_service.dart';
import '../../../core/services/location_service.dart';
import '../../../core/services/mesh_service.dart';
import '../../../core/services/sos_service.dart';
import '../../sos/active_sos_screen.dart';
import '../../sos/active_sos_view.dart';
import '../../sos/sos_actions.dart';
import '../../sos/sos_status.dart';

/// The top of Home: current connectivity, then either the SOS button or,
/// while an SOS is active, its live status. SOS is always the first
/// actionable element on the screen.
class SosHomePanel extends StatelessWidget {
  const SosHomePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final active = context.watch<SosService>().activeAlert;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NetworkStatusBar(),
        const SizedBox(height: 16),
        if (active == null) const SosHeroButton() else ActiveSosCard(alert: active),
      ],
    );
  }
}

/// Internet / offline mesh / GPS at a glance — each with text, not only
/// colour, and only from real service state.
class NetworkStatusBar extends StatelessWidget {
  const NetworkStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final hasNetwork = context.watch<ConnectivityStatusService>().hasNetwork;
    final location = context.watch<LocationService>();

    final meshRunning = mesh.isAdvertising || mesh.isDiscovering;
    final meshText = mesh.connectedCount > 0
        ? '${mesh.connectedCount} connected'
        : meshRunning
            ? 'Searching…'
            : 'Off';
    final gpsText = location.currentPosition != null
        ? 'Available'
        : switch (location.status) {
            LocationStatus.permissionDenied || LocationStatus.permissionDeniedForever => 'No permission',
            LocationStatus.serviceDisabled => 'Turned off',
            LocationStatus.acquiring => 'Locating…',
            _ => 'No fix',
          };

    return Row(
      children: [
        _StatusTile(
          icon: hasNetwork == false ? Icons.cloud_off : Icons.cloud_done,
          label: 'Internet',
          value: hasNetwork == null ? 'Checking…' : (hasNetwork ? 'Network on' : 'Unavailable'),
          ok: hasNetwork == true,
        ),
        const SizedBox(width: 8),
        _StatusTile(
          icon: Icons.hub,
          label: 'Offline mesh',
          value: meshText,
          ok: mesh.connectedCount > 0,
          onTap: () => Navigator.pushNamed(context, '/mesh'),
        ),
        const SizedBox(width: 8),
        _StatusTile(
          icon: location.currentPosition != null ? Icons.gps_fixed : Icons.gps_off,
          label: 'Location',
          value: gpsText,
          ok: location.currentPosition != null,
          onTap: () => Navigator.pushNamed(context, '/map'),
        ),
      ],
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.icon, required this.label, required this.value, required this.ok, this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final bool ok;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppColors.connectedGreen : AppColors.textSecondary;
    return Expanded(
      child: Semantics(
        button: onTap != null,
        label: '$label: $value',
        excludeSemantics: true,
        child: Material(
          color: AppColors.cardDark,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: color.withValues(alpha: 0.4)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(height: 2),
                  Text(label, style: TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                  Text(
                    value,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The large SOS control. A single tap starts a short, cancellable
/// countdown — fast in an emergency, but an accidental tap never sends
/// anything by itself.
class SosHeroButton extends StatelessWidget {
  const SosHeroButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Semantics(
          button: true,
          label: 'SOS. Send emergency alert. Starts a $sosCountdownSeconds second countdown you can cancel.',
          excludeSemantics: true,
          child: Material(
            key: const Key('home-sos-button'),
            color: const Color(0xFFB71C1C),
            shape: const CircleBorder(),
            elevation: 8,
            shadowColor: AppColors.emergencyRed,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => startSos(context),
              child: const SizedBox(
                width: 200,
                height: 200,
                // Scales the label down inside the fixed circle at large
                // text sizes instead of overflowing it.
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.emergency, color: Colors.white, size: 56),
                        SizedBox(height: 4),
                        Text(
                          'SOS',
                          style: TextStyle(
                              color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 4),
                        ),
                        Text(
                          'SEND EMERGENCY\nALERT',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Tap once — you get $sosCountdownSeconds seconds to cancel. Works without internet.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        TextButton.icon(
          key: const Key('home-sos-details'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pushNamed(context, '/sos'),
          icon: const Icon(Icons.tune, size: 18),
          label: const Text('Choose emergency type or add a message'),
        ),
      ],
    );
  }
}

/// Live status of the active SOS, with the actions that matter now.
class ActiveSosCard extends StatelessWidget {
  const ActiveSosCard({super.key, required this.alert});

  final SosAlert alert;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('active-sos-card'),
      decoration: BoxDecoration(
        color: AppColors.emergencyRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.emergencyRed, width: 2),
      ),
      padding: const EdgeInsets.all(16),
      child: ActiveSosStatusBuilder(
        alert: alert,
        builder: (context, elapsed, lines) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              liveRegion: true,
              label: 'SOS active for ${formatElapsed(elapsed)}',
              excludeSemantics: true,
              child: Row(
                children: [
                  const Icon(Icons.emergency_share, color: AppColors.emergencyRed, size: 32),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'SOS ACTIVE',
                      style: TextStyle(color: AppColors.emergencyRed, fontSize: 24, fontWeight: FontWeight.w900),
                    ),
                  ),
                  Text(
                    formatElapsed(elapsed),
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${alert.category.name[0].toUpperCase()}${alert.category.name.substring(1)} emergency · '
              'started ${TimeOfDay.fromDateTime(alert.timestamp).format(context)}',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const Divider(height: 20),
            for (final line in lines) SosStatusRow(line: line),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('active-sos-details'),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ActiveSosScreen()),
                    ),
                    icon: const Icon(Icons.info_outline),
                    label: const Text('Details'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    key: const Key('active-sos-end'),
                    onPressed: () => confirmAndCancelSos(context),
                    icon: const Icon(Icons.check_circle),
                    label: const Text("I'm safe"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.safeGreen,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
