import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/services/emergency_communication_service.dart';

/// The ONE place every screen renders a trust-tier badge — so no screen
/// invents its own wording, icon, or color for what is otherwise the
/// same underlying claim (Section 14/33's "never collapse into a generic
/// Verified" requirement). Always shows exactly one of the four required
/// labels (UNVERIFIED / ORIGIN VERIFIED / BACKEND VERIFIED / DELIVERY
/// CONFIRMED — [TrustTierLabel]), and tapping it opens the full
/// explanation of what that label does and does NOT mean.
class TrustTierBadge extends StatelessWidget {
  final EmergencyTrustTier tier;

  const TrustTierBadge({super.key, required this.tier});

  static final _copy = {
    TrustTierLabel.unverified: (
      icon: Icons.help_outline,
      label: 'UNVERIFIED',
      color: AppColors.textSecondary,
      explanation: 'No one has cryptographically confirmed who sent this event yet. It may '
          'still be genuine — it may have arrived over the mesh network before reaching a '
          'device or the backend that could check its signature, or its origin device has '
          'never registered a signing key. This does not confirm or deny the emergency is '
          'genuine, that the location is accurate, or that any rescue service has been '
          'notified.',
    ),
    TrustTierLabel.originVerified: (
      icon: Icons.shield_outlined,
      label: 'ORIGIN VERIFIED',
      color: AppColors.primaryOrange,
      explanation: 'This device checked the cryptographic signature itself and confirmed the '
          'event has not been altered since it was signed, and that whoever signed it holds '
          'the matching private key. This does NOT confirm that key belongs to a real, '
          'registered ResQNet account — only ResQNet\'s own backend can confirm that (see '
          'BACKEND VERIFIED). It also does not confirm the emergency is genuine, that the '
          'location is accurate, or that any rescue service has been notified.',
    ),
    TrustTierLabel.backendVerified: (
      icon: Icons.verified_user,
      label: 'BACKEND VERIFIED',
      color: AppColors.connectedGreen,
      explanation: 'ResQNet\'s backend independently checked this event\'s signature against a '
          'key that device registered while online, and confirmed which registered account '
          'sent it. This does not confirm the emergency is genuine, that the location is '
          'accurate, or that any rescue team has responded.',
    ),
    TrustTierLabel.deliveryConfirmed: (
      icon: Icons.done_all,
      label: 'DELIVERY CONFIRMED',
      color: AppColors.connectedGreen,
      explanation: 'This event was confirmed delivered beyond simply being recorded by the '
          'backend. This does not confirm the emergency is genuine, that the location is '
          'accurate, or that any rescue team has responded.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final label = trustTierLabelFor(tier);
    final copy = _copy[label]!;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: AppColors.surfaceDark,
          title: Row(
            children: [
              Icon(copy.icon, color: copy.color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(copy.label, style: TextStyle(color: AppColors.textPrimary, fontSize: 16)),
              ),
            ],
          ),
          content: Text(copy.explanation, style: TextStyle(color: AppColors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: copy.color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: copy.color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(copy.icon, size: 12, color: copy.color),
            const SizedBox(width: 4),
            Text(
              copy.label,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: copy.color),
            ),
            const SizedBox(width: 2),
            Icon(Icons.info_outline, size: 11, color: copy.color.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}
