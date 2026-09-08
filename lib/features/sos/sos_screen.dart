import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/location_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../../features/auth/auth_service.dart';

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
    {'type': SosCategory.medical, 'icon': Icons.local_hospital, 'label': 'Medical', 'color': Color(0xFFD32F2F)},
    {'type': SosCategory.fire, 'icon': Icons.local_fire_department, 'label': 'Fire', 'color': Color(0xFFFF6F00)},
    {'type': SosCategory.flood, 'icon': Icons.water, 'label': 'Flood', 'color': Color(0xFF1565C0)},
    {'type': SosCategory.trapped, 'icon': Icons.terrain, 'label': 'Trapped', 'color': Color(0xFF6D4C41)},
    {'type': SosCategory.rescue, 'icon': Icons.emergency, 'label': 'Rescue', 'color': Color(0xFFF9A825)},
    {'type': SosCategory.general, 'icon': Icons.warning, 'label': 'General', 'color': Color(0xFF616161)},
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
    HapticFeedback.heavyImpact();
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CountdownDialog(),
    );
    if (confirmed == true) {
      await _broadcastSos();
    }
  }

  Future<void> _broadcastSos() async {
    if (_isSending) return;
    setState(() => _isSending = true);

    final auth = context.read<AuthService>();

    try {
      int? battery;
      try {
        battery = await Battery().batteryLevel;
      } catch (_) {}

      await SosDispatchService.dispatch(
        context,
        userId: auth.currentUser?.uid ?? 'unknown',
        userName: auth.currentUser?.displayName ??
            auth.currentUser?.phoneNumber ??
            'Unknown User',
        category: _selectedCategory,
        message: _messageController.text.trim().isEmpty
            ? 'Emergency! Need help!'
            : _messageController.text.trim(),
        batteryLevel: battery,
      );

      HapticFeedback.vibrate();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('SOS Broadcast Sent!'),
              ],
            ),
            backgroundColor: AppColors.emergencyRed,
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationService>();

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Send SOS',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold)),
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
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.emergencyRed.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.emergencyRed),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber, color: AppColors.emergencyRed),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This alerts nearby devices, your trusted contacts, '
                      'local police/disaster helplines (by SMS — you\'ll '
                      'need to tap send once), and all ResQNet users once online.',
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
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
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
                          ? color.withOpacity(0.2)
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
                            color: isSelected
                                ? color
                                : AppColors.textSecondary,
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
                hintStyle:
                    TextStyle(color: AppColors.textSecondary),
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
                                color: AppColors.textSecondary,
                                fontSize: 12),
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
                        _batteryLevel != null
                            ? '$_batteryLevel%'
                            : '--',
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

class _CountdownDialog extends StatefulWidget {
  const _CountdownDialog();

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog>
    with SingleTickerProviderStateMixin {
  int _seconds = 5;
  Timer? _timer;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      HapticFeedback.mediumImpact();
      if (_seconds == 1) {
        t.cancel();
        if (mounted) Navigator.pop(context, true);
      } else {
        if (mounted) setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceDark,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber,
              color: AppColors.emergencyRed, size: 48),
          const SizedBox(height: 16),
          Text('Sending SOS in',
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          const SizedBox(height: 8),
          Text(
            '$_seconds',
            style: const TextStyle(
                color: AppColors.emergencyRed,
                fontSize: 64,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _animController,
            builder: (_, __) => LinearProgressIndicator(
              value: 1 - _animController.value,
              backgroundColor: AppColors.cardDark,
              color: AppColors.emergencyRed,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Reaches nearby devices, trusted contacts, and police/disaster '
            'helplines automatically — an SMS opens for you to tap send.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                HapticFeedback.heavyImpact();
                Navigator.pop(context, false);
              },
              icon: Icon(Icons.cancel,
                  color: AppColors.textSecondary),
              label: Text('Cancel SOS',
                  style: TextStyle(color: AppColors.textSecondary)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: AppColors.textSecondary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}