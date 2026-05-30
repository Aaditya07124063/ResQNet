import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/mesh_service.dart';
import '../../widgets/emergency_card.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final sorted = [...mesh.messages]
      ..sort((a, b) => b.priority.index.compareTo(a.priority.index));
    final critical =
        sorted.where((m) => m.priority == PriorityLevel.critical).length;

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: const Text('Rescue Dashboard',
            style: TextStyle(color: Colors.white)),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            _card('Total', '${mesh.messages.length}', AppColors.infoBlue),
            const SizedBox(width: 8),
            _card('Critical', '$critical', AppColors.criticalRed),
            const SizedBox(width: 8),
            _card('Devices', '${mesh.connectedCount}', AppColors.safeGreen),
          ]),
        ),
        Expanded(
          child: sorted.isEmpty
              ? const Center(
                  child: Text('No emergencies received yet.',
                      style: TextStyle(color: AppColors.textSecondary)))
              : ListView.builder(
                  itemCount: sorted.length,
                  itemBuilder: (_, i) => EmergencyCard(message: sorted[i])),
        ),
      ]),
    );
  }

  Widget _card(String label, String value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: AppColors.cardDark,
              borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 28,
                    fontWeight: FontWeight.bold)),
            Text(label,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ]),
        ),
      );
}
