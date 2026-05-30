import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/ai_service.dart';
import '../../widgets/emergency_card.dart';
import '../../widgets/device_tile.dart';

class MeshScreen extends StatefulWidget {
  const MeshScreen({super.key});
  @override
  State<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends State<MeshScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _msgCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  void _send() {
    if (_msgCtrl.text.trim().isEmpty) return;
    final mesh = context.read<MeshService>();
    final ai = context.read<AiService>();
    final text = _msgCtrl.text.trim();
    final msg = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: 'me',
      senderName: 'Me',
      content: text,
      type: ai.classify(text),
      priority: ai.prioritize(text),
      timestamp: DateTime.now(),
    );
    mesh.broadcast(msg);
    _msgCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text(
          'Mesh Network  •  ${mesh.connectedCount} connected',
          style: const TextStyle(color: Colors.white),
        ),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.emergencyRed,
          tabs: const [Tab(text: 'Messages'), Tab(text: 'Devices')],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [
        Column(children: [
          Expanded(
            child: mesh.messages.isEmpty
                ? const Center(
                    child: Text('No messages yet.',
                        style: TextStyle(color: AppColors.textSecondary)))
                : ListView.builder(
                    itemCount: mesh.messages.length,
                    itemBuilder: (_, i) =>
                        EmergencyCard(message: mesh.messages[i])),
          ),
          Container(
            color: AppColors.surfaceDark,
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Type emergency message...',
                    hintStyle:
                        const TextStyle(color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.cardDark,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: AppColors.emergencyRed,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.white),
                  onPressed: _send,
                ),
              ),
            ]),
          ),
        ]),
        mesh.devices.isEmpty
            ? const Center(
                child: Text(
                'No nearby devices found.\nEnable Bluetooth & WiFi.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ))
            : ListView.builder(
                itemCount: mesh.devices.length,
                itemBuilder: (_, i) => DeviceTile(
                  device: mesh.devices[i],
                  onConnect: () =>
                      mesh.connectTo(mesh.devices[i].deviceId),
                )),
      ]),
    );
  }
}