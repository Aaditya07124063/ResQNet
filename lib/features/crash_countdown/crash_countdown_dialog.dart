import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/emergency_message.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/mesh_service.dart';
import '../../core/services/profile_service.dart';

class CrashCountdownDialog extends StatefulWidget {
  const CrashCountdownDialog({super.key});

  @override
  State<CrashCountdownDialog> createState() => _CrashCountdownDialogState();
}

class _CrashCountdownDialogState extends State<CrashCountdownDialog> {
  static const int _totalSeconds = 20;
  int _remaining = _totalSeconds;
  Timer? _timer;
  bool _sosSent = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _startCountdown();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      HapticFeedback.mediumImpact();
      if (_remaining <= 1) {
        t.cancel();
        _sendSOS();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  Future<void> _sendSOS() async {
    if (_sosSent) return;
    _sosSent = true;

    final crashService = context.read<CrashDetectionService>();
    final meshService = context.read<MeshService>();
    final profileService = context.read<ProfileService>();

    double? lat, lng;
    try {
      final pos = await Geolocator.getCurrentPosition()
          .timeout(const Duration(seconds: 5));
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        lat = last?.latitude;
        lng = last?.longitude;
      } catch (_) {}
    }

    final speed = crashService.speedAtImpact;
    final speedStr = speed > 0
        ? ' | Speed at impact: ${speed.toStringAsFixed(0)} km/h'
        : '';
    final name =
        profileService.name.isNotEmpty ? profileService.name : 'Unknown';

    final message = EmergencyMessage(
      id: const Uuid().v4(),
      senderId: name,
      senderName: name,
      message: '🚗 VEHICLE CRASH DETECTED — AUTO SOS$speedStr\n'
          'Blood: ${profileService.bloodGroup} | Allergies: ${profileService.allergies}',
      type: EmergencyType.rescue,
      priority: PriorityLevel.critical,
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
    );

    await meshService.broadcastMessage(message);
    HapticFeedback.vibrate();

    if (mounted) {
      crashService.resetCrash();
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🚨 Crash SOS sent automatically'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _iAmOk() {
    _timer?.cancel();
    context.read<CrashDetectionService>().resetCrash();
    HapticFeedback.selectionClick();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remaining / _totalSeconds;

    return WillPopScope(
      onWillPop: () async => false,
      child: AlertDialog(
        backgroundColor: Colors.red.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.car_crash, color: Colors.white, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'CRASH DETECTED',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Vehicle crash detected.\nSending SOS in...',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 80,
                  height: 80,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 6,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
                Text(
                  '$_remaining',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          ElevatedButton.icon(
            onPressed: _iAmOk,
            icon: const Icon(Icons.check_circle, color: Colors.red),
            label: const Text(
              "I'M OK — CANCEL",
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
          ),
        ],
      ),
    );
  }
}