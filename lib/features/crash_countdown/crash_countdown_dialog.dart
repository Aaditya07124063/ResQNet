import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/crash_detection_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../../features/auth/auth_service.dart';

/// Shown only when CrashDetectionService's multi-signal confidence has
/// already crossed the confirmation threshold (see CrashConfig) — this
/// dialog is the last, human-in-the-loop step, not the trigger itself.
/// The user gets the full countdown to say "I'm OK" and cancel, or can
/// send SOS immediately without waiting it out.
class CrashCountdownDialog extends StatefulWidget {
  const CrashCountdownDialog({super.key});

  @override
  State<CrashCountdownDialog> createState() => _CrashCountdownDialogState();
}

class _CrashCountdownDialogState extends State<CrashCountdownDialog> {
  late int _totalSeconds;
  late int _remaining;
  Timer? _timer;
  bool _sosSent = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _totalSeconds =
        context.read<CrashDetectionService>().confirmationCountdown.inSeconds;
    _remaining = _totalSeconds;
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
    _timer?.cancel();

    final crashService = context.read<CrashDetectionService>();
    final profileService = context.read<ProfileService>();
    final auth = context.read<AuthService>();
    crashService.confirm();

    final evidence = crashService.evidence;
    final speedDrop = evidence.speedDropMps;
    final speedStr =
        speedDrop != null && speedDrop > 0 ? ' | Speed drop: ${(speedDrop * 3.6).toStringAsFixed(0)} km/h' : '';
    final name = profileService.name.isNotEmpty
        ? profileService.name
        : (auth.currentUser?.displayName ??
            auth.currentUser?.phoneNumber ??
            'Unknown');

    // Same routing as a manual SOS: mesh (nearby devices), trusted
    // contacts + police/disaster hotline (SMS, works offline), and all
    // ResQNet users once online — a crash is exactly when someone might
    // be unable to trigger SOS themselves.
    await SosDispatchService.dispatch(
      context,
      userId: auth.currentUser?.uid ?? 'unknown',
      userName: name,
      category: SosCategory.rescue,
      message: '🚗 VEHICLE CRASH DETECTED — AUTO SOS '
          '(confidence ${(evidence.totalConfidence * 100).toStringAsFixed(0)}%)$speedStr\n'
          'Blood: ${profileService.bloodGroup} | Allergies: ${profileService.allergies}',
      eventSource: 'crash_detection',
    );
    HapticFeedback.vibrate();

    if (mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🚨 Crash SOS sent'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _iAmOk() {
    _timer?.cancel();
    context.read<CrashDetectionService>().cancel();
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
    final crashService = context.watch<CrashDetectionService>();
    final evidence = crashService.evidence;
    final progress = _remaining / _totalSeconds;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: Colors.red.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.car_crash, color: Colors.white, size: 28),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'POSSIBLE ACCIDENT DETECTED',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Sending SOS in...',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Confidence: ${(evidence.totalConfidence * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Impact ${(evidence.accelerationScore * 100).toStringAsFixed(0)}% · '
                    'Rotation ${(evidence.gyroScore * 100).toStringAsFixed(0)}% · '
                    'Speed drop ${(evidence.speedDropScore * 100).toStringAsFixed(0)}% · '
                    'Stillness ${(evidence.postImpactScore * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _iAmOk,
                  icon: const Icon(Icons.check_circle, color: Colors.red),
                  label: const Text(
                    "I'M OK — CANCEL",
                    style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sosSent ? null : _sendSOS,
                  icon: const Icon(Icons.sos, color: Colors.white),
                  label: const Text(
                    'SEND SOS NOW',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white70),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
