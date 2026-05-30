import 'package:flutter/material.dart';
import '../core/models/emergency_message.dart';
import '../core/constants/app_colors.dart';
import '../core/utils/message_priority.dart';
import 'priority_badge.dart';

class EmergencyCard extends StatelessWidget {
  final EmergencyMessage message;
  const EmergencyCard({super.key, required this.message});

  IconData _typeIcon(EmergencyType t) {
    switch (t) {
      case EmergencyType.medical: return Icons.local_hospital;
      case EmergencyType.fire: return Icons.local_fire_department;
      case EmergencyType.flood: return Icons.water;
      case EmergencyType.rescue: return Icons.search;
      case EmergencyType.trapped: return Icons.warning;
      case EmergencyType.general: return Icons.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.cardDark,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: priorityColor(message.priority), width: 4),
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(_typeIcon(message.type),
                color: priorityColor(message.priority), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message.senderName,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold)),
            ),
            PriorityBadge(priority: message.priority),
          ]),
          const SizedBox(height: 6),
          Text(message.content,
              style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Row(children: [
            if (message.latitude != null)
              Text(
                '${message.latitude!.toStringAsFixed(4)}, ${message.longitude!.toStringAsFixed(4)}',
                style: const TextStyle(color: AppColors.infoBlue, fontSize: 11),
              ),
            const Spacer(),
            if (message.isRelayed)
              const Text('Relayed',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
          ]),
        ]),
      ),
    );
  }
}
