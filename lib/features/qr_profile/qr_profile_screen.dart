import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/services/profile_service.dart';

class QrProfileScreen extends StatefulWidget {
  const QrProfileScreen({super.key});

  @override
  State<QrProfileScreen> createState() => _QrProfileScreenState();
}

class _QrProfileScreenState extends State<QrProfileScreen> {
  String? _qrData;
  String _locationText = 'Fetching location...';
  bool _loading = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _buildQrData();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _buildQrData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _buildQrData() async {
    final profile = context.read<ProfileService>();

    double? lat;
    double? lng;
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

    if (mounted) {
      setState(() {
        _locationText = (lat != null && lng != null)
            ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
            : 'Location unavailable';
      });
    }

    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final data = StringBuffer();
    data.writeln('=== RESQNET EMERGENCY PROFILE ===');
    data.writeln('Name: ${profile.name}');
    data.writeln('Blood Group: ${profile.bloodGroup}');
    data.writeln(
        'Allergies: ${profile.allergies.isNotEmpty ? profile.allergies : 'None'}');
    data.writeln(
        'Medications: ${profile.medications.isNotEmpty ? profile.medications : 'None'}');
    data.writeln('Emergency Contact: ${profile.emergencyContact}');
    if (lat != null && lng != null) {
      data.writeln('Location: $lat, $lng');
      data.writeln('Maps: https://maps.google.com/?q=$lat,$lng');
    }
    data.writeln('Generated: $dateStr');
    data.writeln('App: ResQNet Emergency');

    if (mounted) {
      setState(() {
        _qrData = data.toString();
        _loading = false;
      });
    }
  }

  void _copyData() {
    if (_qrData == null) return;
    Clipboard.setData(ClipboardData(text: _qrData!));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency data copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileService>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency QR Code'),
        actions: [
          if (_qrData != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy data',
              onPressed: _copyData,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade300),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Show this QR to paramedics. They can scan it with any phone camera — no app or internet needed.',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: _qrData!,
                      version: QrVersions.auto,
                      size: 260,
                      backgroundColor: Colors.white,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                    ),
                  ),
                  const SizedBox(height: 20),
                  _InfoCard(
                    icon: Icons.person,
                    label: 'Name',
                    value: profile.name.isNotEmpty ? profile.name : 'Not set',
                    color: Colors.blue,
                  ),
                  const SizedBox(height: 8),
                  _InfoCard(
                    icon: Icons.bloodtype,
                    label: 'Blood Group',
                    value: profile.bloodGroup.isNotEmpty
                        ? profile.bloodGroup
                        : 'Not set',
                    color: Colors.red,
                  ),
                  const SizedBox(height: 8),
                  _InfoCard(
                    icon: Icons.warning_amber,
                    label: 'Allergies',
                    value:
                        profile.allergies.isNotEmpty ? profile.allergies : 'None',
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 8),
                  _InfoCard(
                    icon: Icons.medication,
                    label: 'Medications',
                    value: profile.medications.isNotEmpty
                        ? profile.medications
                        : 'None',
                    color: Colors.purple,
                  ),
                  const SizedBox(height: 8),
                  _InfoCard(
                    icon: Icons.location_on,
                    label: 'Location',
                    value: _locationText,
                    color: Colors.green,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _loading = true);
                      _buildQrData();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Location'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'QR auto-refreshes every 30 seconds',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 11, color: color)),
                Text(
                  value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}