import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/profile_service.dart';

/// "Include medical information in automatic SOS" — off unless the user
/// turns it on. The text states exactly what is shared, when, and with whom.
class MedicalSharingSetting extends StatelessWidget {
  const MedicalSharingSetting({super.key});

  static const explanation = [
    'Off unless you turn it on.',
    'What: your blood group and allergies. Your medications are never included.',
    'When: only when crash or earthquake detection sends an SOS for you.',
    'Who can see it: ResQNet responders authorised to handle emergencies, and '
        'people nearby whose ResQNet app receives your SOS over the offline network '
        '— this can include people you don\'t know.',
    'Trusted contacts get a notification that you need help; it does not contain these details.',
    'Messages and locations you share from the mesh screen never include medical information.',
    'If your phone can\'t sign the SOS, the medical details are left out.',
  ];

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<ProfileService>();
    return Container(
      key: const Key('medical-auto-sos-setting'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      decoration: BoxDecoration(color: AppColors.cardDark, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                Icon(Icons.medical_information_outlined, color: AppColors.textSecondary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Include medical information in automatic SOS',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                Switch(
                  key: const Key('medical-auto-sos-switch'),
                  value: profile.includeMedicalInAutoSos,
                  onChanged: (value) => profile.setIncludeMedicalInAutoSos(value),
                  activeThumbColor: AppColors.connectedGreen,
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (final line in explanation)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text(line, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
