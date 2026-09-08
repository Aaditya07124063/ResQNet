import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/backend_session_controller.dart';
import '../../core/network/token_storage.dart';
import '../../core/network/websocket_client.dart';

class AuthService extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  AuthService() {
    // Phase 4C: relay backendSession's own notifications as this class's
    // notifications too, so anything watching AuthService via Provider
    // (e.g. _AuthGate) rebuilds when backend auth state changes, not just
    // when AuthService's own fields change.
    backendSession.addListener(notifyListeners);
  }

  User? get currentUser => _auth.currentUser;
  bool get isLoggedIn => _auth.currentUser != null;

  String _verificationId = '';
  bool _isLoading = false;
  String _error = '';

  bool get isLoading => _isLoading;
  String get error => _error;

  // Phone OTP
  Future<void> sendOtp({
    required String phoneNumber,
    required Function onCodeSent,
    required Function(String) onError,
  }) async {
    _isLoading = true;
    _error = '';
    notifyListeners();
    try {
      await _auth.verifyPhoneNumber(
        phoneNumber: phoneNumber,
        verificationCompleted: (PhoneAuthCredential credential) async {
          await _auth.signInWithCredential(credential);
          notifyListeners();
        },
        verificationFailed: (FirebaseAuthException e) {
          _error = e.message ?? 'Verification failed';
          _isLoading = false;
          notifyListeners();
          onError(_error);
        },
        codeSent: (String verificationId, int? resendToken) {
          _verificationId = verificationId;
          _isLoading = false;
          notifyListeners();
          onCodeSent();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          _verificationId = verificationId;
        },
      );
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      onError(_error);
    }
  }

  // Verify OTP
  Future<bool> verifyOtp(String otp) async {
    _isLoading = true;
    notifyListeners();
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: otp,
      );
      await _auth.signInWithCredential(credential);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = 'Invalid OTP. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Phase 20 (Firebase removal): the old Firebase-credential Google
  // Sign-In path (`signInWithGoogle()`, using
  // `FirebaseAuth.signInWithCredential`) has been removed — confirmed
  // unused anywhere in the app (login_screen.dart's Google button has
  // called `signInWithGoogleBackend()` below since Phase 4C). Firebase
  // Auth itself is NOT removed here — phone sign-in (below) still
  // depends on it entirely, with no backend replacement (Phase 8/9 SMS
  // provider system was never built).

  // Sign Out
  Future<void> signOut() async {
    await _auth.signOut();
    await _googleSignIn.signOut();
    // Phase 4B: logout state synchronization — ending the Firebase
    // session also ends any backend session, so the two never disagree
    // about whether the user is signed in. signOutBackend() is already
    // safe to call even when no backend session was ever established
    // (Google login isn't cut over yet, so today this is a no-op for
    // almost everyone) — it no-ops on a missing refresh token and always
    // clears local tokens regardless of network outcome.
    await signOutBackend();
    backendSession.markSignedOut();
    // Communication phase: a stale connection authenticated as the
    // now-signed-out user must never keep receiving realtime events —
    // the next sign-in (same or different account) calls
    // CommunicationService.initialize(), which reconnects fresh.
    ResQNetWebSocketClient.instance.disconnect();
    notifyListeners();
  }

  // --- ResQNet backend session (Phase 4 — additive, not yet wired into the
  // login UI). This talks to the new backend's POST /auth/google, which
  // verifies the Google ID token itself via google-auth-library rather
  // than going through FirebaseAuth.signInWithCredential. It is
  // deliberately separate from signInWithGoogle() above: the existing
  // Firebase-based flow keeps working untouched, and this is exercised
  // once the backend is actually deployed (still blocked on the open
  // domain/VPS questions in docs/AUDIT.md) and can be tested end-to-end.
  //
  // Reuses the SAME Google idToken v6's `GoogleSignIn().signIn()` already
  // retrieves — no google_sign_in package upgrade needed for this step;
  // see docs/DONE.md for why that upgrade is being deferred separately.

  bool _backendLoading = false;
  bool get backendLoading => _backendLoading;

  /// Phase 4B: observable backend-session state (unknown / restoring /
  /// authenticated / unauthenticated), separate from this class so it
  /// stays unit-testable without Firebase (see backend_session_controller.dart's
  /// doc comment). `_AuthGate` (lib/app.dart) reads this to track backend
  /// state in parallel with Firebase — it does NOT currently change which
  /// screen is shown; Firebase's authStateChanges() remains the sole gate
  /// until Phase 4C/4D.
  final BackendSessionController backendSession = BackendSessionController();

  Future<bool> isBackendSignedIn() async =>
      (await TokenStorage.instance.readAccessToken()) != null;

  /// Phase 4A/4B session-state foundation: determines whether the backend
  /// session is (or can be restored to be) authenticated right now —
  /// checking the stored access token's own expiry locally first, and
  /// falling back to exactly one refresh attempt if needed. Updates
  /// [backendSession] as a side effect so the UI can observe the result.
  /// Does NOT touch Firebase or change what `_AuthGate` (lib/app.dart)
  /// gates navigation on — wiring this into the actual gate decision is
  /// Phase 4C/4D, not this phase.
  Future<bool> restoreBackendSession() async {
    await backendSession.restore();
    return backendSession.status == BackendSessionStatus.authenticated;
  }

  /// Signs in against the ResQNet backend using a Google ID token — this
  /// is now `login_screen.dart`'s primary Google sign-in path (Phase 4C).
  /// Never calls FirebaseAuth.signInWithCredential(); never derives
  /// identity from a Firebase UID. Returns true on success, false if the
  /// user cancels Google's own account picker (not an error). Throws
  /// [ApiException] for every other failure (including
  /// [ApiException.isNetworkError] when the backend can't be reached at
  /// all) so callers can show a specific, safe message per failure mode
  /// rather than a generic one.
  Future<bool> signInWithGoogleBackend() async {
    _backendLoading = true;
    notifyListeners();
    try {
      GoogleSignInAccount? googleUser;
      try {
        googleUser = await _googleSignIn.signIn();
      } catch (_) {
        // e.g. a PlatformException from missing/misconfigured Google Play
        // Services — a real failure, distinct from "user cancelled"
        // (which is a null result below, not a thrown error).
        throw ApiException.network('Google sign-in is not available right now');
      }
      if (googleUser == null) return false;

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null) {
        throw const ApiException(
          statusCode: 0,
          code: 'NO_ID_TOKEN',
          message: 'Google did not return an ID token',
        );
      }

      final response = await ApiClient.instance.post(
        '/auth/google',
        body: {'idToken': idToken},
      );
      final session = response['session'] as Map<String, dynamic>;
      await TokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );
      // The backend is now authoritative for this login — mark the
      // session directly rather than re-running restore(), which would
      // be a redundant round trip immediately after a login that just
      // proved the session is good.
      backendSession.markAuthenticated();
      return true;
    } finally {
      _backendLoading = false;
      notifyListeners();
    }
  }

  /// Revokes the ResQNet backend session (does not touch Firebase/Google
  /// sign-in state — call alongside signOut() once the two are unified).
  Future<void> signOutBackend() async {
    final refreshToken = await TokenStorage.instance.readRefreshToken();
    if (refreshToken != null) {
      try {
        await ApiClient.instance.postNoContent(
          '/auth/logout',
          body: {'refreshToken': refreshToken},
          auth: true,
        );
      } on ApiException {
        // Best-effort revoke — still clear local tokens even if the
        // network call fails, so the device-side session ends regardless.
      }
    }
    await TokenStorage.instance.clear();
  }
}