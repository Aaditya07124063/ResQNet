import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/location_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/sos_service.dart';
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

  static const List<Map<String, dynamic>> _categories = [
    {'type': SosCategory.medical, 'icon': Icons.local_hospital, 'label': 'Medical', 'color': Color(0xFFD32F2F)},
    {'type': SosCategory.fire, 'icon': Icons.local_fire_department, 'label': 'Fire', 'color': Color(0xFFFF6F00)},
    {'type': SosCategory.flood, 'icon': Icons.water, 'label': 'Flood', 'color': Color(0xFF1565C0)},
    {'type': SosCategory.trapped, 'icon': Icons.terrain, 'label': 'Trapped', 'color': Color(0xFF6D4C41)},
    {'type': SosCategory.rescue, 'icon': Icons.emergency, 'label': 'Rescue', 'color': Color(0xFFF9A825)},
    {'type': SosCategory.general, 'icon': Icons.warning, 'label': 'General', 'color': Color(0xFF616161)},
  ];

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _broadcastSos() async {
    if (_isSending) return;
    setState(() => _isSending = true);

    final auth = context.read<AuthService>();
    final sos = context.read<SosService>();
    final mesh = context.read<MeshService>();

    try {
      final alert = await sos.triggerSos(
        userId: auth.currentUser?.uid ?? 'unknown',
        userName: auth.currentUser?.displayName ??
            auth.currentUser?.phoneNumber ??
            'Unknown User',
        category: _selectedCategory,
        message: _messageController.text.trim().isEmpty
            ? 'Emergency! Need help!'
            : _messageController.text.trim(),
      );

      final broadcastMsg = sos.sosToBroadcastMessage(
        alert,
        auth.currentUser?.displayName ??
            auth.currentUser?.phoneNumber ??
            'Unknown',
      );
      await mesh.broadcast(broadcastMsg);

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
          SnackBar(content: Text('Error: $e'),
              backgroundColor: Colors.red),
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
        title: const Text('Send SOS',
            style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
                      'This will alert ALL nearby devices and notify all ResQNet users.',
                      style: TextStyle(
                          color: AppColors.emergencyRed, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('Emergency Type',
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
                  onTap: () =>
                      setState(() => _selectedCategory = cat['type']),
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
            const Text('Message (Optional)',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _messageController,
              maxLines: 3,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Describe your emergency...',
                hintStyle:
                    const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.surfaceDark,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            if (location.currentPosition != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.cardDark,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on,
                        color: AppColors.connectedGreen, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'GPS: ${location.latitude!.toStringAsFixed(4)}, ${location.longitude!.toStringAsFixed(4)}',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.cardDark,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.location_off,
                        color: AppColors.textSecondary, size: 20),
                    SizedBox(width: 8),
                    Text('GPS not available',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: _isSending ? null : _broadcastSos,
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