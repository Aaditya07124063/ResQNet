import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

class SosButton extends StatefulWidget {
  final VoidCallback onPressed;
  final bool isActive;
  const SosButton({super.key, required this.onPressed, this.isActive = false});

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _scaleAnim,
      builder: (_, child) => Transform.scale(
        scale: widget.isActive ? _scaleAnim.value : 1.0,
        child: child,
      ),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.isActive
                ? AppColors.emergencyRed
                : const Color(0xFFB71C1C),
            boxShadow: [
              BoxShadow(
                color: AppColors.emergencyRed.withOpacity(0.6),
                blurRadius: widget.isActive ? 40 : 20,
                spreadRadius: widget.isActive ? 10 : 5,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.emergency, color: Colors.white, size: 52),
              const SizedBox(height: 6),
              Text(
                widget.isActive ? 'SOS ACTIVE' : 'SOS',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}