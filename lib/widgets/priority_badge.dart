import 'package:flutter/material.dart';
import '../core/models/emergency_message.dart';
import '../core/utils/message_priority.dart';

class PriorityBadge extends StatelessWidget {
  final PriorityLevel priority;
  const PriorityBadge({super.key, required this.priority});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: priorityColor(priority),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        priorityLabel(priority),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
