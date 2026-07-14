import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';
import '../core/constants/app_colors.dart';
import '../core/models/emergency_message.dart';
import '../core/services/ai_service.dart';

class EmergencyCard extends StatelessWidget {
  final EmergencyMessage message;
  const EmergencyCard({super.key, required this.message});

  bool get hasLocation =>
      message.latitude != null && message.longitude != null;

  Future<void> _openMap() async {
    final lat = message.latitude;
    final lng = message.longitude;
    if (lat == null || lng == null) return;
    final uri = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Color _batteryColor(int level) {
    if (level > 50) return AppColors.connectedGreen;
    if (level > 20) return AppColors.primaryOrange;
    return AppColors.emergencyRed;
  }

  IconData _batteryIcon(int level) {
    if (level > 75) return Icons.battery_full;
    if (level > 50) return Icons.battery_5_bar;
    if (level > 25) return Icons.battery_3_bar;
    if (level > 10) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }

  @override
  Widget build(BuildContext context) {
    final bool hasMedical =
        (message.bloodGroup != null && message.bloodGroup!.isNotEmpty) ||
            (message.allergies != null && message.allergies!.isNotEmpty) ||
            (message.medications != null &&
                message.medications!.isNotEmpty);

    return Card(
      color: AppColors.cardDark,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: message.priorityColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                topRight: Radius.circular(12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(message.typeIcon,
                        color: message.priorityColor, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        message.senderName,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: message.priorityColor.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: message.priorityColor),
                      ),
                      child: Text(
                        message.priority.name.toUpperCase(),
                        style: TextStyle(
                            color: message.priorityColor,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  message.message,
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 13),
                ),
                if (hasMedical) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Medical Info',
                            style: TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        if (message.bloodGroup != null &&
                            message.bloodGroup!.isNotEmpty)
                          _medicalRow(Icons.bloodtype,
                              'Blood Group: ${message.bloodGroup}',
                              Colors.red),
                        if (message.allergies != null &&
                            message.allergies!.isNotEmpty)
                          _medicalRow(Icons.warning_amber,
                              'Allergies: ${message.allergies}',
                              Colors.orange),
                        if (message.medications != null &&
                            message.medications!.isNotEmpty)
                          _medicalRow(Icons.medication,
                              'Medications: ${message.medications}',
                              Colors.blue),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.access_time,
                        size: 12, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      DateFormat('HH:mm').format(message.timestamp),
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                    ),
                    if (message.batteryLevel != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        _batteryIcon(message.batteryLevel!),
                        size: 12,
                        color: _batteryColor(message.batteryLevel!),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${message.batteryLevel}%',
                        style: TextStyle(
                            fontSize: 11,
                            color: _batteryColor(message.batteryLevel!)),
                      ),
                    ],
                    if (message.isRelayed) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.sync,
                          size: 12, color: AppColors.accentBlue),
                      const SizedBox(width: 2),
                      Text('Relayed (${message.hopCount})',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppColors.accentBlue)),
                    ],
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.volume_up,
                          size: 18, color: Colors.white70),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () =>
                          context.read<AiService>().speak(message.message),
                    ),
                    if (hasLocation) ...[
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _openMap,
                        icon: const Icon(Icons.map, size: 14),
                        label: const Text('View on Map',
                            style: TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentBlue,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _medicalRow(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 11, color: color),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}