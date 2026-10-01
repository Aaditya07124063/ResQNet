import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/emergency_communication_service.dart';
import '../../core/services/mesh_service.dart';
import '../../widgets/trust_tier_badge.dart';

/// Detail of an emergency received from another device over the offline
/// mesh — the destination of an offline SOS notification.
class ReceivedEmergencyScreen extends StatelessWidget {
  const ReceivedEmergencyScreen({super.key, required this.eventId});

  final String eventId;

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    EmergencyMessage? message;
    for (final m in mesh.messages) {
      if (m.id == eventId) {
        message = m;
        break;
      }
    }
    final cancellation = mesh.cancellationFor(eventId);

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Emergency nearby', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      body: message == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This alert is no longer stored on this device. Alerts received over the mesh are kept only '
                  'while ResQNet is running.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            )
          : _Detail(message: message, cancellation: cancellation),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.message, required this.cancellation});

  final EmergencyMessage message;
  final MeshCancellation? cancellation;

  @override
  Widget build(BuildContext context) {
    final lat = message.latitude;
    final lng = message.longitude;
    final cancelled = cancellation;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (cancelled != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (cancelled.verified ? AppColors.safeGreen : AppColors.warningAmber).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(cancelled.verified ? Icons.check_circle : Icons.help_outline,
                    color: cancelled.verified ? AppColors.safeGreen : AppColors.warningAmber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cancelled.verified
                        ? 'The sender cancelled this SOS.'
                        : 'A device reported this SOS as cancelled, but it could not be confirmed that the '
                            'sender sent that. Treat the emergency as still active.',
                    style: TextStyle(color: AppColors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Icon(message.typeIcon, color: message.priorityColor, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message.senderName.isEmpty ? 'Someone nearby' : message.senderName,
                style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TrustTierBadge(tier: trustTierForReceivedMessage(message)),
        const SizedBox(height: 12),
        Text(message.message, style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
        const SizedBox(height: 12),
        Text(
          'Sent ${message.timestamp.toLocal().toString().substring(0, 16)} · '
          'reached you via ${message.hopCount == 0 ? 'direct connection' : '${message.hopCount} relaying device(s)'}',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        if (message.batteryLevel != null)
          Text('Sender battery: ${message.batteryLevel}%',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        const SizedBox(height: 16),
        if (lat != null && lng != null) ...[
          Text('Location: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
              style: TextStyle(color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('https://maps.google.com/?q=$lat,$lng'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.map),
            label: const Text('Open location in maps'),
            style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/map'),
            icon: const Icon(Icons.offline_pin),
            label: const Text('Show on offline map'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ] else
          Text('The sender\'s location was not included.', style: TextStyle(color: AppColors.textSecondary)),
        const SizedBox(height: 16),
        Text(
          'If you can help safely, go to them or contact local emergency services with this location.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ],
    );
  }
}
