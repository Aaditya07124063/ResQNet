import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/seismic_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../../features/auth/auth_service.dart';

/// Shown only when SeismicService's STA/LTA + duration + oscillation
/// confidence has already crossed the confirmation threshold — the
/// DROP/COVER/HOLD ON guidance appears immediately (that's useful
/// regardless of anything else), but SOS itself still goes through the
/// same human-in-the-loop countdown as a crash: "I'm safe" cancels it,
/// an explicit action or a timeout sends it.
class EarthquakeAlertDialog extends StatefulWidget {
  const EarthquakeAlertDialog({super.key});

  @override
  State<EarthquakeAlertDialog> createState() => _EarthquakeAlertDialogState();
}

class _EarthquakeAlertDialogState extends State<EarthquakeAlertDialog> {
  Timer? _hapticTimer;
  Timer? _countdownTimer;
  late int _totalSeconds;
  late int _remaining;
  bool _sosSent = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    // Continuous strong vibration to wake/alert the user.
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 700), (_) => HapticFeedback.heavyImpact());

    _totalSeconds = context.read<SeismicService>().confirmationCountdown.inSeconds;
    _remaining = _totalSeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining <= 1) {
        t.cancel();
        _sendSOS();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _dismiss() {
    if (_sosSent) return;
    _hapticTimer?.cancel();
    _countdownTimer?.cancel();
    context.read<SeismicService>().cancel();
    HapticFeedback.selectionClick();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _sendSOS() async {
    if (_sosSent) return;
    // Once sending starts, "cancel" here would only close the dialog while
    // the SOS still goes out — the button is disabled and the user ends
    // the SOS from Home ("I'm safe") instead.
    setState(() => _sosSent = true);
    _hapticTimer?.cancel();
    _countdownTimer?.cancel();

    final seismicService = context.read<SeismicService>();
    final profileService = context.read<ProfileService>();
    final auth = context.read<AuthService>();
    // Captured before any await: the auto-SOS must be sent even if this
    // dialog is disposed while it is being prepared.
    final deps = SosDispatchDeps.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    seismicService.confirm();

    final evidence = seismicService.evidence;
    final name = profileService.name.isNotEmpty
        ? profileService.name
        : (auth.currentUser?.displayName ?? auth.currentUser?.phoneNumber ?? 'Unknown');

    await profileService.loadMedicalSharingPreference();
    final result = await SosDispatchService.dispatchWith(
      deps,
      userId: await auth.currentSenderId(),
      userName: name,
      category: SosCategory.earthquake,
      message: '🌍 EARTHQUAKE DETECTED — AUTO SOS '
          '(detector score ${(evidence.totalConfidence * 100).toStringAsFixed(0)}%)',
      eventSource: 'earthquake_detection',
      // Blood group and allergies only if the user opted in (off by default).
      medicalSummary: profileService.automaticSosMedicalSummary,
    );
    HapticFeedback.vibrate();

    if (mounted) navigator.pop();
    messenger.showSnackBar(
      SnackBar(
        content:
            Text(result.alreadyActive ? 'Your SOS was already active — it continues.' : '🚨 Earthquake SOS activated'),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  void dispose() {
    _hapticTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final evidence = context.watch<SeismicService>().evidence;
    final progress = _remaining / _totalSeconds;

    return PopScope(
      canPop: false,
      child: Dialog.fullscreen(
        backgroundColor: Colors.red.shade900,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.crisis_alert, color: Colors.white, size: 72),
                const SizedBox(height: 16),
                const Text(
                  '⚠️ EARTHQUAKE DETECTED',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('🔻 DROP to the ground', style: TextStyle(color: Colors.white, fontSize: 18)),
                      SizedBox(height: 8),
                      Text('🛡️ COVER under sturdy furniture', style: TextStyle(color: Colors.white, fontSize: 18)),
                      SizedBox(height: 8),
                      Text('✊ HOLD ON until shaking stops', style: TextStyle(color: Colors.white, fontSize: 18)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stay away from windows, mirrors, and heavy objects.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Sending SOS in...',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 5,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                    Text(
                      '$_remaining',
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Detector score: ${(evidence.totalConfidence * 100).toStringAsFixed(0)}% (not a verified probability) '
                  '(based on this device — nearby devices are checked in the background)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _sosSent ? null : _dismiss,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: Text(
                      _sosSent ? 'SOS SENDING — END IT FROM HOME' : "I'M SAFE — CANCEL SOS",
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
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
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
