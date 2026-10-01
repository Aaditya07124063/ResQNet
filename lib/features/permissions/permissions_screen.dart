import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/constants/app_colors.dart';
import '../../core/utils/permission_handler.dart';

/// One-time explanation shown before the system permission prompts, so
/// the user knows why each is needed. Resolves when the user continues.
Future<void> showPermissionExplainer(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    backgroundColor: AppColors.surfaceDark,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Before you need help',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              'ResQNet will ask for a few permissions. SOS always works, but each one adds a way to reach help.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            for (final group in resqnetPermissionGroups())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_iconFor(group.id), color: AppColors.accentBlue),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group.title,
                              style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                          Text(group.reason, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => Navigator.pop(sheetContext),
              style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    ),
  );
}

IconData _iconFor(String id) => switch (id) {
      'nearby' => Icons.hub,
      'location' => Icons.location_on,
      _ => Icons.notifications_active,
    };

/// Current status of each permission, with a way to fix it — including
/// "permanently denied", which only the system settings can undo.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> with WidgetsBindingObserver {
  Map<String, GroupPermissionState> _states = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Returning from the settings app re-reads the real status.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final next = <String, GroupPermissionState>{};
    for (final group in resqnetPermissionGroups()) {
      try {
        next[group.id] = await groupState(group);
      } catch (_) {
        next[group.id] = GroupPermissionState.denied;
      }
    }
    if (mounted) setState(() => _states = next);
  }

  Future<void> _fix(ResQNetPermissionGroup group) async {
    if (_states[group.id] == GroupPermissionState.permanentlyDenied) {
      await openAppSettings();
    } else {
      await requestGroup(group);
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.surfaceDark,
        title: Text('Permissions', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final group in resqnetPermissionGroups())
            Card(
              color: AppColors.cardDark,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_iconFor(group.id), color: AppColors.accentBlue),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(group.title,
                              style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
                        ),
                        _StateLabel(state: _states[group.id]),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(group.reason, style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    if (_states[group.id] != null && _states[group.id] != GroupPermissionState.granted)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                          onPressed: () => _fix(group),
                          child: Text(
                              _states[group.id] == GroupPermissionState.permanentlyDenied ? 'Open settings' : 'Allow'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StateLabel extends StatelessWidget {
  const _StateLabel({required this.state});

  final GroupPermissionState? state;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = switch (state) {
      GroupPermissionState.granted => ('Allowed', AppColors.safeGreen, Icons.check_circle),
      GroupPermissionState.denied => ('Not allowed', AppColors.warningAmber, Icons.error_outline),
      GroupPermissionState.permanentlyDenied => ('Blocked', AppColors.emergencyOrange, Icons.block),
      null => ('Checking…', AppColors.textSecondary, Icons.hourglass_empty),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
