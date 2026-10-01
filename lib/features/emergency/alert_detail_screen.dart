import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/app_colors.dart';

/// Detail for a backend-pushed alert (a trusted contact's SOS, a
/// corroborated earthquake) opened from a notification. Built only from
/// the notification's validated parameters, so it works even when the
/// server cannot be reached.
class AlertDetailScreen extends StatelessWidget {
  const AlertDetailScreen({super.key, required this.params});

  final Map<String, String> params;

  @override
  Widget build(BuildContext context) {
    final isQuake = params['alert'] == 'earthquake';
    final lat = double.tryParse(params['latitude'] ?? '');
    final lng = double.tryParse(params['longitude'] ?? '');
    final title = params['title'] ?? (isQuake ? 'Possible earthquake' : 'Emergency');
    final body = params['body'] ?? '';

    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text(isQuake ? 'Earthquake alert' : 'SOS alert',
            style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Icon(isQuake ? Icons.public : Icons.emergency, color: AppColors.emergencyRed, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(body, style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
          ],
          const SizedBox(height: 16),
          if (lat != null && lng != null) ...[
            Text(
              '${isQuake ? 'Approximate area' : 'Their location'}: ${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://maps.google.com/?q=$lat,$lng'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.map),
              label: const Text('Open in maps'),
              style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ] else
            Text('No location was included.', style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 16),
          Text(
            isQuake
                ? 'This is based on sensor reports from several phones and is not an official warning. '
                    'Follow guidance from local authorities.'
                : 'Try to contact them directly. If they may be in danger, call local emergency services '
                    'and give them this location.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
