import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/services/seismic_service.dart';

class EarthquakeAlertDialog extends StatefulWidget {
  const EarthquakeAlertDialog({super.key});

  @override
  State<EarthquakeAlertDialog> createState() => _EarthquakeAlertDialogState();
}

class _EarthquakeAlertDialogState extends State<EarthquakeAlertDialog> {
  Timer? _hapticTimer;
  int _secondsElapsed = 0;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    // Continuous strong vibration to wake/alert the user
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      HapticFeedback.heavyImpact();
      setState(() => _secondsElapsed = (t.tick * 700 / 1000).round());
      // Auto-dismiss after 30 seconds
      if (t.tick * 700 >= 30000) _dismiss();
    });
  }

  void _dismiss() {
    _hapticTimer?.cancel();
    context.read<SeismicService>().resetAlert();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _hapticTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
      child: Dialog.fullscreen(
        backgroundColor: Colors.red.shade900,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.crisis_alert,
                    color: Colors.white, size: 90),
                const SizedBox(height: 20),
                const Text(
                  '⚠️ EARTHQUAKE\nVIBRATION DETECTED',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('🔻 DROP to the ground',
                          style: TextStyle(color: Colors.white, fontSize: 18)),
                      SizedBox(height: 8),
                      Text('🛡️ COVER under sturdy furniture',
                          style: TextStyle(color: Colors.white, fontSize: 18)),
                      SizedBox(height: 8),
                      Text('✊ HOLD ON until shaking stops',
                          style: TextStyle(color: Colors.white, fontSize: 18)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stay away from windows, mirrors,\nand heavy objects.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: _dismiss,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                  child: const Text(
                    'I\'M SAFE — DISMISS',
                    style: TextStyle(
                        color: Colors.red, fontWeight: FontWeight.bold),
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