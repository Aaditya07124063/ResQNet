import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/services/check_in_service.dart';

class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  Timer? _uiTimer;

  static const Map<String, Duration> _intervals = {
    '15 minutes': Duration(minutes: 15),
    '30 minutes': Duration(minutes: 30),
    '1 hour': Duration(hours: 1),
    '2 hours': Duration(hours: 2),
    '4 hours': Duration(hours: 4),
    '8 hours': Duration(hours: 8),
  };

  @override
  void initState() {
    super.initState();
    // Refresh countdown display every second
    _uiTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    if (d.isNegative) return '0:00';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<CheckInService>();

    return Scaffold(
      appBar: AppBar(title: const Text('Safety Check-In Timer')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: service.isActive
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Check in before the timer runs out',
                      style: TextStyle(fontSize: 15)),
                  const SizedBox(height: 24),
                  Text(
                    _format(service.remaining),
                    style: TextStyle(
                      fontSize: 56,
                      fontWeight: FontWeight.bold,
                      color: service.remaining.inMinutes < 5
                          ? Colors.red
                          : Colors.green,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'If it expires, an SOS with your location\nis sent automatically over the mesh.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    height: 90,
                    child: ElevatedButton(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        service.checkIn();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ Checked in — timer restarted'),
                            backgroundColor: Colors.green,
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                      child: const Text("I'M OK — CHECK IN",
                          style: TextStyle(
                              fontSize: 22,
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: service.stop,
                    icon: const Icon(Icons.stop_circle, color: Colors.red),
                    label: const Text('Stop Timer',
                        style: TextStyle(color: Colors.red)),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  const Text(
                    'Going somewhere risky alone?\nTrekking, farming, night travel?',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Pick a check-in interval. If you don\'t tap "I\'m OK" in time, ResQNet automatically sends an SOS with your last location.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),
                  ..._intervals.entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: OutlinedButton(
                        onPressed: () => service.start(e.value),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(e.key,
                            style: const TextStyle(fontSize: 16)),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}