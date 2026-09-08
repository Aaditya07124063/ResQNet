import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/services/app_shortcut_service.dart';

// Deliberately does NOT call AppShortcutService.init() — that talks to a
// real platform channel (quick_actions), which has no native
// implementation under `flutter test`. What's actually new/untested-
// elsewhere here is the pendingAction consumption contract HomeScreen
// relies on to gate the shortcut-triggered SOS navigation; init() itself
// only delegates to the official, separately-tested quick_actions package.
void main() {
  group('AppShortcutService.pendingAction', () {
    test('starts as null (no shortcut launch by default)', () {
      final service = AppShortcutService();
      expect(service.pendingAction.value, isNull);
    });

    test('consume() clears a set action back to null', () {
      final service = AppShortcutService();
      service.pendingAction.value = AppShortcutService.sosActionType;

      service.consume();

      expect(service.pendingAction.value, isNull);
    });

    test('consume() is safe to call when already null (idempotent)', () {
      final service = AppShortcutService();

      expect(() => service.consume(), returnsNormally);
      expect(service.pendingAction.value, isNull);
    });

    test('notifies listeners exactly once per actual value change', () {
      final service = AppShortcutService();
      var notifications = 0;
      service.pendingAction.addListener(() => notifications++);

      service.pendingAction.value = AppShortcutService.sosActionType;
      expect(notifications, 1);

      service.consume();
      expect(notifications, 2);
    });

    test(
      'a listener reading the action type sees the exact sosActionType constant '
      '(this is what HomeScreen compares against to decide whether to navigate)',
      () {
        final service = AppShortcutService();
        String? observed;
        service.pendingAction.addListener(() {
          observed = service.pendingAction.value;
        });

        service.pendingAction.value = AppShortcutService.sosActionType;

        expect(observed, 'action_send_sos');
        expect(observed, AppShortcutService.sosActionType);
      },
    );
  });
}
