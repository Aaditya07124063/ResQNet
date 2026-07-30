import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/ai_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/models/emergency_message.dart';
import '../../widgets/emergency_card.dart';
import '../../widgets/device_tile.dart';

class MeshScreen extends StatefulWidget {
  const MeshScreen({super.key});

  @override
  State<MeshScreen> createState() => _MeshScreenState();
}

class _MeshScreenState extends State<MeshScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _messageController = TextEditingController();
  bool _isAnonymous = false;
  String _selectedLanguage = 'English';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProfileService>().loadProfile();
    });
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

  Future<void> _shareLocation() async {
    final mesh = context.read<MeshService>();
    final location = context.read<LocationService>();
    final profile = context.read<ProfileService>();
    final pos = location.currentPosition;

    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GPS not available')),
      );
      return;
    }

    if (profile.name.isEmpty) {
      await profile.loadProfile();
    }

    final msg = EmergencyMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: FirebaseAuth.instance.currentUser?.uid ?? 'anonymous',
      senderName: _isAnonymous
          ? 'Anonymous'
          : (profile.name.isNotEmpty ? profile.name : 'Unknown'),
      message: '📍 Sharing my location',
      type: EmergencyType.rescue,
      priority: PriorityLevel.high,
      latitude: pos.latitude,
      longitude: pos.longitude,
      timestamp: DateTime.now(),
      bloodGroup: _isAnonymous ? null : profile.bloodGroup,
      allergies: _isAnonymous ? null : profile.allergies,
      medications: _isAnonymous ? null : profile.medications,
    );

    mesh.broadcastMessage(msg);
  }

  void _startListening() {
    final ai = context.read<AiService>();
    ai.startListening(
      onResult: (text) {
        if (mounted) {
          setState(() => _messageController.text = text);
        }
      },
      language: _selectedLanguage,
    );
  }

  void _stopListening() {
    context.read<AiService>().stopListening();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = context.watch<MeshService>();
    final ai = context.watch<AiService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Flexible(
              child: Text('Mesh',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 18)),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: mesh.connectedCount > 0
                    ? AppColors.connectedGreen.withOpacity(0.2)
                    : AppColors.textSecondary.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${mesh.connectedCount}',
                style: TextStyle(
                    color: mesh.connectedCount > 0
                        ? AppColors.connectedGreen
                        : AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: _isAnonymous ? 'Anonymous: ON' : 'Anonymous: OFF',
            icon: Icon(
              _isAnonymous ? Icons.visibility_off : Icons.visibility,
              color: _isAnonymous
                  ? AppColors.emergencyRed
                  : AppColors.textSecondary,
            ),
            onPressed: () => setState(() => _isAnonymous = !_isAnonymous),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.translate, color: AppColors.textPrimary),
            onSelected: (lang) => setState(() => _selectedLanguage = lang),
            itemBuilder: (_) => AiService.supportedLanguages.keys
                .map((lang) =>
                    PopupMenuItem(value: lang, child: Text(lang)))
                .toList(),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.emergencyRed,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textSecondary,
          tabs: [
            Tab(text: 'Messages (${mesh.messages.length})'),
            Tab(text: 'Devices (${mesh.discoveredDevices.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: AppColors.emergencyRed.withOpacity(0.15),
            padding:
                const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: const Text(
              '⚠️ For emergency use only',
              style:
                  TextStyle(color: AppColors.emergencyRed, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),

          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                mesh.messages.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.message_outlined,
                                color: AppColors.textSecondary, size: 48),
                            SizedBox(height: 12),
                            Text('No messages yet',
                                style: TextStyle(
                                    color: AppColors.textSecondary)),
                            SizedBox(height: 8),
                            Text('Send an SOS to broadcast a message',
                                style: TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 12)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: mesh.messages.length,
                        itemBuilder: (_, i) {
                          final msg = mesh.messages[i];
                          final langCode =
                              AiService.supportedLanguages[
                                      _selectedLanguage] ??
                                  'en';
                          if (langCode == 'en') {
                            return EmergencyCard(message: msg);
                          }
                          return FutureBuilder<String>(
                            future: ai.translateMessage(
                                msg.message, langCode),
                            builder: (_, snap) {
                              final translated =
                                  snap.data ?? msg.message;
                              return EmergencyCard(
                                  message: msg.copyWith(
                                      message: translated));
                            },
                          );
                        },
                      ),

                Platform.isIOS
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'iOS uses Multipeer Connectivity automatically.\nKeep Bluetooth and WiFi ON.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: AppColors.textSecondary),
                          ),
                        ),
                      )
                    : mesh.discoveredDevices.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.wifi_off,
                                    color: AppColors.textSecondary,
                                    size: 48),
                                const SizedBox(height: 12),
                                const Text('No nearby devices found',
                                    style: TextStyle(
                                        color: AppColors.textSecondary)),
                                const SizedBox(height: 8),
                                Text(
                                  mesh.isDiscovering
                                      ? 'Scanning... Make sure Bluetooth & WiFi are ON'
                                      : 'Scan stopped',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: mesh.discoveredDevices.length,
                            itemBuilder: (_, i) {
                              final device = mesh.discoveredDevices[i];
                              return DeviceTile(
                                device: device,
                                onConnect: () => mesh
                                    .connectToDevice(device.deviceId),
                              );
                            },
                          ),
              ],
            ),
          ),

          Container(
            color: AppColors.surfaceDark,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _shareLocation,
                icon: const Icon(Icons.location_on,
                    color: AppColors.accentBlue, size: 18),
                label: const Text('📍 Share My Location',
                    style: TextStyle(color: AppColors.accentBlue)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.accentBlue),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                ),
              ),
            ),
          ),

          Container(
            color: AppColors.surfaceDark,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTapDown: (_) => _startListening(),
                  onTapUp: (_) => _stopListening(),
                  onTapCancel: () => _stopListening(),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ai.isListening
                          ? Colors.green
                          : AppColors.cardDark,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      ai.isListening ? Icons.mic : Icons.mic_none,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style:
                        const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Type emergency message...',
                      hintStyle: const TextStyle(
                          color: AppColors.textSecondary),
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
        ],
      ),
    );
  }
}