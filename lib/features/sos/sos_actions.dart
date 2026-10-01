import 'dart:async';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/emergency_outbox_entry.dart';
import '../../core/models/sos_alert.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/sos_dispatch_service.dart';
import '../auth/auth_service.dart';

/// Seconds between pressing SOS and it being sent — long enough to cancel
/// an accidental press, short enough not to cost time in a real emergency
/// ("Send now" skips it).
const sosCountdownSeconds = 5;

/// Announces [message] to screen readers (no-op without a view).
void announceToScreenReader(BuildContext context, String message) {
  final view = View.maybeOf(context);
  if (view == null) return;
  unawaited(SemanticsService.sendAnnouncement(view, message, TextDirection.ltr));
}

/// Identity is only a label on an SOS: a sign-in/identity failure (no
/// session, identity service unavailable) must never stop an SOS from being sent,
/// so these lookups fall back instead of throwing.
AuthService? _authOrNull(BuildContext context) {
  try {
    return context.read<AuthService>();
  } catch (_) {
    return null;
  }
}

Future<String> _senderId(AuthService? auth) async {
  try {
    return await auth?.currentSenderId() ?? 'anonymous';
  } catch (e) {
    debugPrint('SOS sender id unavailable: $e');
    return 'anonymous';
  }
}

String sosSenderName(BuildContext context) {
  final profile = context.read<ProfileService>();
  if (profile.name.trim().isNotEmpty) return profile.name.trim();
  try {
    final user = _authOrNull(context)?.currentUser;
    return user?.displayName ?? user?.phoneNumber ?? 'ResQNet user';
  } catch (_) {
    return 'ResQNet user';
  }
}

/// Shows the cancellable countdown. Resolves true to send, false if
/// cancelled.
Future<bool> showSosCountdown(BuildContext context, {int seconds = sosCountdownSeconds}) async {
  HapticFeedback.heavyImpact();
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => SosCountdownDialog(seconds: seconds),
  );
  return confirmed ?? false;
}

/// Countdown → dispatch → honest result. Shared by every manual SOS entry
/// point so they all behave identically.
Future<SosDispatchResult?> startSos(
  BuildContext context, {
  SosCategory category = SosCategory.general,
  String message = '',
  bool skipCountdown = false,
}) async {
  // Everything the send needs is captured now, while the context is live:
  // once the user lets the countdown finish, the SOS must go out even if
  // this screen is gone by then.
  final deps = SosDispatchDeps.of(context);
  final auth = _authOrNull(context);
  final messenger = ScaffoldMessenger.of(context);
  final view = View.maybeOf(context);
  final name = sosSenderName(context);
  void announce(String text) {
    if (view != null) unawaited(SemanticsService.sendAnnouncement(view, text, TextDirection.ltr));
  }

  if (!skipCountdown && !await showSosCountdown(context)) {
    announce('SOS cancelled');
    return null;
  }

  int? battery;
  try {
    battery = await Battery().batteryLevel;
  } catch (_) {}

  try {
    final result = await SosDispatchService.dispatchWith(
      deps,
      userId: await _senderId(auth),
      userName: name,
      category: category,
      message: message.trim().isEmpty ? 'Emergency! Need help!' : message.trim(),
      batteryLevel: battery,
    );
    HapticFeedback.vibrate();
    final text = result.alreadyActive
        ? 'Your SOS is already active — it keeps being sent.'
        : 'SOS activated. Sending to nearby devices and the ResQNet server.';
    announce(text);
    messenger.showSnackBar(SnackBar(backgroundColor: AppColors.emergencyRed, content: Text(text)));
    return result;
  } catch (e) {
    debugPrint('SOS dispatch failed: $e');
    const text = 'Could not start the SOS on this device. Call your local emergency number if you can.';
    announce(text);
    messenger.showSnackBar(const SnackBar(backgroundColor: Colors.red, content: Text(text)));
    return null;
  }
}

/// Asks how the SOS ended, then cancels it everywhere it can.
Future<void> confirmAndCancelSos(BuildContext context) async {
  // Captured before the dialog: a confirmed cancellation must complete even
  // if the screen behind the dialog is disposed meanwhile.
  final deps = SosDispatchDeps.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final view = View.maybeOf(context);
  final senderName = sosSenderName(context);
  final resolution = await showDialog<SosResolution>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surfaceDark,
      title: Text('End your SOS?', style: TextStyle(color: AppColors.textPrimary)),
      content: Text(
        'Nearby devices and your contacts will be told the emergency is over.',
        style: TextStyle(color: AppColors.textSecondary),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        _DialogChoice(
          label: "I'm safe now",
          icon: Icons.check_circle,
          color: AppColors.safeGreen,
          onPressed: () => Navigator.pop(dialogContext, SosResolution.resolved),
        ),
        _DialogChoice(
          label: 'It was a false alarm',
          icon: Icons.undo,
          color: AppColors.warningAmber,
          onPressed: () => Navigator.pop(dialogContext, SosResolution.falseAlarm),
        ),
        _DialogChoice(
          label: 'Keep SOS active',
          icon: Icons.emergency,
          color: AppColors.emergencyRed,
          onPressed: () => Navigator.pop(dialogContext),
        ),
      ],
    ),
  );
  if (resolution == null) return;

  final outcome = await SosDispatchService.cancelWith(deps, resolution: resolution, senderName: senderName);
  if (outcome == null) return;
  HapticFeedback.mediumImpact();
  final text = switch (outcome.remoteState) {
    ResolutionSyncState.synced => 'SOS ended. Nearby devices and the ResQNet server have been told.',
    ResolutionSyncState.pending =>
      'SOS ended on this phone. Nearby devices are being told; the server will be updated when you are online.',
    _ => 'SOS ended. Nearby devices are being told.',
  };
  if (view != null) unawaited(SemanticsService.sendAnnouncement(view, text, TextDirection.ltr));
  messenger.showSnackBar(SnackBar(content: Text(text)));
}

class _DialogChoice extends StatelessWidget {
  const _DialogChoice({required this.label, required this.icon, required this.color, required this.onPressed});

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: color),
        label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          side: BorderSide(color: color),
        ),
      ),
    );
  }
}

/// Full-attention countdown before an SOS is sent. Announced to screen
/// readers each second, with a large Cancel target and a "Send now" option.
class SosCountdownDialog extends StatefulWidget {
  const SosCountdownDialog({super.key, this.seconds = sosCountdownSeconds});

  final int seconds;

  @override
  State<SosCountdownDialog> createState() => _SosCountdownDialogState();
}

class _SosCountdownDialogState extends State<SosCountdownDialog> {
  late int _remaining = widget.seconds;
  Timer? _timer;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) announceToScreenReader(context, 'SOS will be sent in $_remaining seconds. Tap cancel to stop.');
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_remaining <= 1) {
        _close(true);
        return;
      }
      HapticFeedback.mediumImpact();
      setState(() => _remaining--);
      announceToScreenReader(context, '$_remaining');
    });
  }

  void _close(bool send) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    HapticFeedback.heavyImpact();
    Navigator.of(context).pop(send);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remaining / widget.seconds;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surfaceDark,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.emergency, color: AppColors.emergencyRed, size: 48),
            const SizedBox(height: 12),
            Text('Sending SOS in', style: TextStyle(color: AppColors.textSecondary, fontSize: 16)),
            Semantics(
              liveRegion: true,
              label: '$_remaining seconds until SOS is sent',
              excludeSemantics: true,
              child: Text(
                '$_remaining',
                key: const Key('sos-countdown-value'),
                style: const TextStyle(color: AppColors.emergencyRed, fontSize: 72, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: AppColors.cardDark,
              color: AppColors.emergencyRed,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 16),
            Text(
              'Alerts nearby ResQNet devices (works offline), the ResQNet server when online, '
              'and opens an SMS to your trusted contacts and local helplines.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                key: const Key('sos-countdown-cancel'),
                onPressed: () => _close(false),
                icon: const Icon(Icons.close, size: 28),
                label: const Text('CANCEL', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(64),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('sos-countdown-send-now'),
              onPressed: () => _close(true),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: const Text(
                'Send now',
                style: TextStyle(color: AppColors.emergencyRed, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
