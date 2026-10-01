import 'package:flutter/foundation.dart';
import 'backend_session.dart';

/// Observable ResQNet backend-session state. `AuthService` owns an
/// instance and exposes it to the UI; `_AuthGate` (lib/app.dart) decides
/// between sign-in and Home solely from [status].
enum BackendSessionStatus {
  /// Restoration hasn't run yet this app launch.
  unknown,

  /// A restore() call is currently in flight.
  restoring,

  /// A usable backend session exists (stored access token is valid, or a
  /// refresh just succeeded).
  authenticated,

  /// No backend session, or it could not be restored/refreshed.
  unauthenticated,
}

class BackendSessionController extends ChangeNotifier {
  BackendSessionStatus _status = BackendSessionStatus.unknown;
  BackendSessionStatus get status => _status;

  /// Runs the Phase 4A restoration flow (BackendSession.restore()) and
  /// updates [status] accordingly. Re-entrant-safe: a second call made
  /// while one is already in flight is a no-op rather than starting a
  /// second, redundant restoration.
  Future<void> restore() async {
    if (_status == BackendSessionStatus.restoring) return;
    _status = BackendSessionStatus.restoring;
    notifyListeners();

    final restored = await BackendSession.restore();

    _status = restored ? BackendSessionStatus.authenticated : BackendSessionStatus.unauthenticated;
    notifyListeners();
  }

  /// Called immediately after a fresh backend login (Phase 4C —
  /// signInWithGoogleBackend()) has already saved tokens via TokenStorage.
  /// Sets the observable state directly rather than re-running restore()
  /// (which would be a redundant round trip immediately after a login
  /// that just proved the session is good).
  void markAuthenticated() {
    _status = BackendSessionStatus.authenticated;
    notifyListeners();
  }

  /// Called when the app signs out (or the backend ends the session) so
  /// the observable state reflects
  /// "no session" immediately, without needing another restore() round
  /// trip. Does not itself touch token storage — the caller
  /// (AuthService.signOut()) is responsible for actually clearing tokens
  /// via signOutBackend(), which this only mirrors the resulting state of.
  void markSignedOut() {
    _status = BackendSessionStatus.unauthenticated;
    notifyListeners();
  }
}
