import 'package:flutter/foundation.dart';
import 'package:quick_actions/quick_actions.dart';

/// Bridges Android's App Shortcuts / iOS's Home Screen Quick Actions
/// (long-press the app icon) into the app.
///
/// This is deliberately the ONLY thing native code is asked to do: launch
/// (or foreground) the Flutter app and report which shortcut was used.
/// Neither platform lets a shortcut run arbitrary code or hold a
/// secure-storage-backed session outside the running app process, so the
/// actual authenticated `/api/v1/sos` call, the existing eventId/
/// idempotency logic, and the existing send confirmation UI all still run
/// entirely inside the normal app — see [pendingAction]'s doc comment for
/// exactly how a launch is consumed.
class AppShortcutService {
  static const sosActionType = 'action_send_sos';

  final QuickActions _quickActions = const QuickActions();

  /// Set to [sosActionType] when the app was just launched (cold start)
  /// or resumed (already running) via the SOS shortcut; `null` otherwise.
  ///
  /// Consumers (currently just [HomeScreen]) must call [consume] once
  /// they've acted on it, so the same launch can't re-trigger navigation
  /// on a later rebuild. This is intentionally a plain [ValueNotifier],
  /// not a [ChangeNotifier] service of its own — nothing about this
  /// class's own identity changes, only this one value.
  final ValueNotifier<String?> pendingAction = ValueNotifier(null);

  /// Registers the shortcut and its launch handler. Call once, before
  /// `runApp` — safe to call before Firebase/auth initialize, since this
  /// only sets up a platform channel and doesn't touch either.
  Future<void> init() async {
    await _quickActions.initialize((type) {
      pendingAction.value = type;
    });
    await _quickActions.setShortcutItems(const [
      ShortcutItem(
        type: sosActionType,
        localizedTitle: 'Send SOS',
        icon: 'ic_shortcut_sos',
      ),
    ]);
  }

  void consume() {
    pendingAction.value = null;
  }
}
