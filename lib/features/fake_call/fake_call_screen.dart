import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FakeCallScreen extends StatefulWidget {
  const FakeCallScreen({super.key});

  @override
  State<FakeCallScreen> createState() => _FakeCallScreenState();
}

class _FakeCallScreenState extends State<FakeCallScreen> {
  bool _answered = false;
  int _callSeconds = 0;
  Timer? _ringTimer;
  Timer? _callTimer;

  @override
  void initState() {
    super.initState();
    // Vibrate like a real incoming call
    _ringTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_answered) HapticFeedback.heavyImpact();
    });
  }

  void _answer() {
    _ringTimer?.cancel();
    setState(() => _answered = true);
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _callSeconds++);
    });
  }

  void _end() {
    _ringTimer?.cancel();
    _callTimer?.cancel();
    Navigator.of(context).pop();
  }

  String get _duration {
    final m = _callSeconds ~/ 60;
    final s = _callSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _ringTimer?.cancel();
    _callTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            Text(
              _answered ? _duration : 'Incoming call...',
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 20),
            const CircleAvatar(
              radius: 55,
              backgroundColor: Colors.blueGrey,
              child: Icon(Icons.person, color: Colors.white, size: 60),
            ),
            const SizedBox(height: 16),
            const Text('Papa',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Mobile +91 98XXXXXX21',
                style: TextStyle(color: Colors.white54, fontSize: 15)),
            const Spacer(),
            if (!_answered)
              Padding(
                padding: const EdgeInsets.only(bottom: 60),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallButton(
                      color: Colors.red,
                      icon: Icons.call_end,
                      label: 'Decline',
                      onTap: _end,
                    ),
                    _CallButton(
                      color: Colors.green,
                      icon: Icons.call,
                      label: 'Accept',
                      onTap: _answer,
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 60),
                child: _CallButton(
                  color: Colors.red,
                  icon: Icons.call_end,
                  label: 'End',
                  onTap: _end,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _CallButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: CircleAvatar(
            radius: 34,
            backgroundColor: color,
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}