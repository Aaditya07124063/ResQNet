import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/sos_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ai_service.dart';

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});
  @override
  State<SosScreen> createState() => _SosScreenState();
}

class _SosScreenState extends State<SosScreen> {
  SosCategory _selected = SosCategory.rescue;
  final _msgCtrl = TextEditingController();
  bool _sent = false;

  static const _categories = [
    (SosCategory.medical, Icons.local_hospital, 'Medical'),
    (SosCategory.fire, Icons.local_fire_department, 'Fire'),
    (SosCategory.flood, Icons.water, 'Flood'),
    (SosCategory.rescue, Icons.search, 'Rescue'),
    (SosCategory.trapped, Icons.warning, 'Trapped'),
    (SosCategory.other, Icons.help, 'Other'),
  ];

  Future<void> _sendSos() async {
    final sos = context.read<SosService>();
    final mesh = context.read<MeshService>();
    final location = context.read<LocationService>();
    final ai = context.read<AiService>();
    final alert = await sos.createAlert(
      category: _selected,
      message: _msgCtrl.text.isEmpty ? _selected.name : _msgCtrl.text,
      locationService: location,
      aiService: ai,
    );
    final msg = sos.alertToMessage(alert);
    await mesh.broadcast(msg);
    setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final location = context.watch<LocationService>();
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.emergencyRed,
        title: const Text('Send SOS',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _sent ? _sentView() : _formView(location),
    );
  }

  Widget _sentView() => Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle, color: AppColors.safeGreen, size: 80),
          const SizedBox(height: 16),
          const Text('SOS Broadcast Sent!',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Nearby devices have been alerted.',
              style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emergencyRed),
            child: const Text('Back to Home'),
          ),
        ]),
      );

  Widget _formView(LocationService location) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Select Emergency Type',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            children: _categories.map((c) {
              final isSelected = _selected == c.$1;
              return GestureDetector(
                onTap: () => setState(() => _selected = c.$1),
                child: Container(
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.emergencyRed
                        : AppColors.cardDark,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected
                          ? AppColors.emergencyRed
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(c.$2, color: Colors.white, size: 32),
                        const SizedBox(height: 4),
                        Text(c.$3,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ]),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          const Text('Message (optional)',
              style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _msgCtrl,
            maxLines: 3,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Describe your situation...',
              hintStyle: const TextStyle(color: AppColors.textSecondary),
              filled: true,
              fillColor: AppColors.cardDark,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.cardDark,
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              const Icon(Icons.location_on, color: AppColors.infoBlue),
              const SizedBox(width: 8),
              Text(
                location.currentPosition != null
                    ? '${location.currentPosition!.latitude.toStringAsFixed(4)}, ${location.currentPosition!.longitude.toStringAsFixed(4)}'
                    : 'Getting GPS location...',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ]),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _sendSos,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.emergencyRed,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('BROADCAST SOS',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 2)),
            ),
          ),
        ]),
      );
}
