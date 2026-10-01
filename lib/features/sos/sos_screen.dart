import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/services/sos_service.dart';
import 'sos_actions.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/location_service.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  SosCategory _selectedCategory = SosCategory.general;
  final _messageController = TextEditingController();
  bool _isSending = false;
  int? _batteryLevel;

  static const List<Map<String, dynamic>> _categories = [
    {
      'type': SosCategory.medical,
      'icon': Icons.local_hospital,
      'label': 'Medical',
      'color': Color(0xFFD32F2F)
    },
    {
      'type': SosCategory.fire,
      'icon': Icons.local_fire_department,
      'label': 'Fire',
      'color': Color(0xFFFF6F00)
    },
    {
      'type': SosCategory.flood,
      'icon': Icons.water,
      'label': 'Flood',
      'color': Color(0xFF1565C0)
    },
    {
      'type': SosCategory.trapped,
      'icon': Icons.terrain,
      'label': 'Trapped',
      'color': Color(0xFF6D4C41)
    },
    {
      'type': SosCategory.rescue,
      'icon': Icons.emergency,
      'label': 'Rescue',
      'color': Color(0xFFF9A825)
    },
    {
      'type': SosCategory.general,
      'icon': Icons.warning,
      'label': 'General',
      'color': Color(0xFF616161)
    },
  ];

  @override
  void initState() {
    super.initState();
    _readBattery();
  }

  Future<void> _readBattery() async {
    try {
      final level = await Battery().batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {}
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
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

  Future<void> _confirmAndSend() async {
    if (_isSending) return;
    setState(() => _isSending = true);
    try {
      final result = await startSos(
        context,
        category: _selectedCategory,
        message: _messageController.text,
      );
      // Back to Home, which now shows the live status of the active SOS.
      if (result != null && mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationService>();
    final alreadyActive = context.watch<SosService>().sosActive;

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Send SOS',
            style: TextStyle(
                color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (alreadyActive)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.emergencyRed,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.emergency_share, color: Colors.white),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Your SOS is already active and still being sent. Sending again will not create a second alert.',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.emergencyRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.emergencyRed),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: AppColors.emergencyRed),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This alerts nearby ResQNet devices (works offline), the ResQNet '
                      'server and your trusted contacts once online, and opens an SMS '
                      'to your contacts and local helplines — you tap send.',
                      style: TextStyle(
                          color: AppColors.emergencyRed, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('Emergency Type',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.1,
              ),
              itemCount: _categories.length,
              itemBuilder: (_, i) {
                final cat = _categories[i];
                final isSelected = _selectedCategory == cat['type'];
                final color = cat['color'] as Color;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _selectedCategory = cat['type']);
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? color.withValues(alpha: 0.2)
                          : AppColors.cardDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected ? color : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(cat['icon'] as IconData,
                            color: isSelected ? color : AppColors.textSecondary,
                            size: 28),
                        const SizedBox(height: 6),
                        Text(cat['label'] as String,
                            style: TextStyle(
                                color: isSelected
                                    ? color
                                    : AppColors.textSecondary,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text('Message (Optional)',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 3,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Describe your emergency...',
                hintStyle: TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceDark,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.cardDark,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          location.currentPosition != null
                              ? Icons.location_on
                              : Icons.location_off,
                          color: location.currentPosition != null
                              ? AppColors.connectedGreen
                              : AppColors.textSecondary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            location.currentPosition != null
                                ? '${location.currentPosition!.latitude.toStringAsFixed(4)}, ${location.currentPosition!.longitude.toStringAsFixed(4)}'
                                : 'GPS not available',
                            style: TextStyle(
                                color: AppColors.textSecondary, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.cardDark,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _batteryLevel != null
                            ? _batteryIcon(_batteryLevel!)
                            : Icons.battery_unknown,
                        color: _batteryLevel != null
                            ? _batteryColor(_batteryLevel!)
                            : AppColors.textSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _batteryLevel != null ? '$_batteryLevel%' : '--',
                        style: TextStyle(
                          color: _batteryLevel != null
                              ? _batteryColor(_batteryLevel!)
                              : AppColors.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _isSending ? null : _confirmAndSend,
                icon: _isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.send, color: Colors.white),
                label: Text(
                  _isSending ? 'Sending SOS...' : 'Broadcast SOS',
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.emergencyRed,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
