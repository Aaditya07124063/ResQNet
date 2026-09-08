import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/ai_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/profile_service.dart';
import '../../widgets/emergency_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final TextEditingController _messageController = TextEditingController();
  bool _isAnonymous = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProfileService>().loadProfile();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final mesh = context.read<MeshService>();
    final ai = context.read<AiService>();
    final location = context.read<LocationService>();
    final profile = context.read<ProfileService>();

    if (profile.name.isEmpty) {
      await profile.loadProfile();
    }

    final type = ai.classifyEmergency(text);
    final priority = ai.assessPriority(text, type);

    final msg = EmergencyMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: FirebaseAuth.instance.currentUser?.uid ?? 'anonymous',
      senderName: _isAnonymous
          ? 'Anonymous'
          : (profile.name.isNotEmpty ? profile.name : 'Unknown'),
      message: text,
      type: type,
      priority: priority,
      latitude: location.currentPosition?.latitude,
      longitude: location.currentPosition?.longitude,
      timestamp: DateTime.now(),
      bloodGroup: _isAnonymous ? null : profile.bloodGroup,
      allergies: _isAnonymous ? null : profile.allergies,
      medications: _isAnonymous ? null : profile.medications,
    );

    mesh.broadcastMessage(msg);
    _messageController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final profile = context.watch<ProfileService>();
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
              ? Center(
                  child: Text('No emergencies received yet.',
                      style: TextStyle(color: AppColors.textSecondary)))
              : ListView.builder(
                  itemCount: sorted.length,
                  itemBuilder: (_, i) => EmergencyCard(message: sorted[i])),
        ),
        Container(
          width: double.infinity,
          color: AppColors.surfaceDark,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(
                _isAnonymous ? Icons.visibility_off : Icons.visibility,
                color: _isAnonymous
                    ? AppColors.emergencyRed
                    : AppColors.connectedGreen,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _isAnonymous
                      ? 'Sending anonymously'
                      : 'Sending as ${profile.name.isNotEmpty ? profile.name : 'yourself'}',
                  style: TextStyle(
                    color: _isAnonymous
                        ? AppColors.emergencyRed
                        : AppColors.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: _isAnonymous,
                activeThumbColor: AppColors.emergencyRed,
                onChanged: (v) => setState(() => _isAnonymous = v),
              ),
            ],
          ),
        ),
        Container(
          color: AppColors.surfaceDark,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style: TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Type emergency message...',
                    hintStyle:
                        TextStyle(color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.cardDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _sendMessage,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: AppColors.emergencyRed,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.send,
                      color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
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
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 12)),
          ]),
        ),
      );
}
