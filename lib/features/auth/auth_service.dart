import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/services/communication_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/trusted_contacts_service.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/backend_session_controller.dart';
import '../../core/network/jwt_utils.dart';
import '../../core/network/token_storage.dart';
import '../../core/network/websocket_client.dart';

/// The signed-in ResQNet user, as returned by `GET /api/v1/me`.
class ResQNetUser {
  const ResQNetUser({required this.id, this.displayName, this.email, this.phoneNumber});

  final String id;
  final String? displayName;
  final String? email;
  final String? phoneNumber;

  factory ResQNetUser.fromJson(Map<String, dynamic> json) => ResQNetUser(
        id: json['id'] as String,
        displayName: json['displayName'] as String?,
        email: json['email'] as String?,
        phoneNumber: json['phoneNumber'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'email': email,
        'phoneNumber': phoneNumber,
      };
}

/// Authentication against the ResQNet backend (Hostinger), which is the
/// only authority for who is signed in:
///
/// - Google: Google Sign-In ID token → `POST /api/v1/auth/google`
/// - Phone: `POST /api/v1/auth/phone/send-otp` → `verify-otp`
///
/// Both store the backend's access/refresh tokens in secure storage
/// ([TokenStorage]) and mark [backendSession] authenticated; [ApiClient]
/// refreshes them. There is no second (Firebase) session.
class AuthService extends ChangeNotifier {
  AuthService({GoogleSignIn? googleSignIn}) : _googleSignIn = googleSignIn ?? GoogleSignIn() {
    // Relay session changes so anything watching AuthService (the auth
    // gate) rebuilds when backend auth state changes.
    backendSession.addListener(notifyListeners);
    // The backend rejected the refresh token: the session is over.
    ApiClient.sessionEnded.addListener(_onSessionEnded);
  }

  final GoogleSignIn _googleSignIn;

  final BackendSessionController backendSession = BackendSessionController();

  static const _userCacheKey = 'resqnet_current_user_v1';
  ResQNetUser? _currentUser;

  /// The signed-in user's profile basics (cached for offline use); null
  /// when signed out or not loaded yet.
  ResQNetUser? get currentUser => _currentUser;

  bool get isLoggedIn => backendSession.status == BackendSessionStatus.authenticated;

  bool _backendLoading = false;
  bool get backendLoading => _backendLoading;

  /// Kept for existing screens; there is only one (backend) loading state.
  bool get isLoading => _backendLoading;

  void _onSessionEnded() {
    if (backendSession.status != BackendSessionStatus.authenticated) return;
    _currentUser = null;
    unawaited(_clearUserCache());
    backendSession.markSignedOut();
    ResQNetWebSocketClient.instance.disconnect();
  }

  @override
  void dispose() {
    ApiClient.sessionEnded.removeListener(_onSessionEnded);
    backendSession.removeListener(notifyListeners);
    super.dispose();
  }

  Future<bool> isBackendSignedIn() async => (await TokenStorage.instance.readAccessToken()) != null;

  /// Identifier used to label locally created messages (mesh senderId) —
  /// the backend session's user id. Never used for backend authorization,
  /// which the backend derives from the request's own JWT.
  Future<String> currentSenderId() async {
    final accessToken = await TokenStorage.instance.readAccessToken();
    if (accessToken != null) {
      final subject = jwtSubject(accessToken);
      if (subject != null) return subject;
    }
    return _currentUser?.id ?? 'anonymous';
  }

  /// Restores the backend session at app start (valid access token, or one
  /// refresh; offline keeps the session). Loads the cached user first so
  /// the app works offline, then refreshes it from `/me` in the background.
  Future<bool> restoreBackendSession() async {
    await backendSession.restore();
    final authenticated = backendSession.status == BackendSessionStatus.authenticated;
    if (authenticated) {
      await _loadUserCache();
      unawaited(refreshCurrentUser());
    } else {
      _currentUser = null;
    }
    notifyListeners();
    return authenticated;
  }

  /// Loads the signed-in user from `GET /api/v1/me`. Best-effort: offline
  /// keeps the cached user.
  Future<void> refreshCurrentUser() async {
    try {
      final response = await ApiClient.instance.get('/me', auth: true);
      final user = response['user'];
      if (user is Map<String, dynamic>) {
        _currentUser = ResQNetUser.fromJson(user);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_userCacheKey, jsonEncode(_currentUser!.toJson()));
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Could not load the current user: $e');
    }
  }

  Future<void> _loadUserCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_userCacheKey);
      if (raw != null) _currentUser = ResQNetUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _currentUser = null;
    }
  }

  Future<void> _clearUserCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_userCacheKey);
      // The medical-sharing opt-in belongs to the person who chose it: the
      // next person to sign in on this phone starts with it OFF.
      await prefs.remove(ProfileService.includeMedicalInAutoSosKey);
      // Personal data cached for the signed-in user. The emergency outbox
      // is deliberately kept: SOS delivery must not depend on being signed
      // in (it is pruned by age instead).
      for (final key in [ProfileService.storageKey, TrustedContactsService.storageKey, CommunicationService.outboxKey]) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  /// Signs out: revokes and clears the backend session, signs out of the
  /// Google account picker, and closes the realtime connection.
  Future<void> signOut() async {
    await signOutBackend();
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      debugPrint('Google sign-out failed: $e');
    }
    _currentUser = null;
    await _clearUserCache();
    backendSession.markSignedOut();
    // A connection authenticated as the signed-out user must not keep
    // receiving realtime events.
    ResQNetWebSocketClient.instance.disconnect();
    notifyListeners();
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

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
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
      await refreshCurrentUser();
      return true;
    } finally {
      _backendLoading = false;
      notifyListeners();
    }
  }

  /// Requests a phone-OTP code from the ResQNet backend — Step 2 of the
  /// Firebase migration (POST /auth/phone/send-otp). This is the app's
  /// only phone sign-in path; the backend generates, delivers (through its
  /// SMS provider system), and verifies the code.
  ///
  /// Throws [ApiException] on any failure, including a rate-limit 429 (IP
  /// or phone-number limited, or the 60s resend cooldown) and a 500 if the
  /// SMS provider itself failed to send. The backend's success response is
  /// deliberately generic and reveals nothing about whether phoneNumber is
  /// already registered — see authRoutes.ts.
  Future<void> sendOtpBackend(String phoneNumber) async {
    _backendLoading = true;
    notifyListeners();
    try {
      await ApiClient.instance
          .post('/auth/phone/send-otp', body: {'phoneNumber': phoneNumber});
    } finally {
      _backendLoading = false;
      notifyListeners();
    }
  }

  /// Verifies a phone-OTP code against the ResQNet backend (POST
  /// /auth/phone/verify-otp) and, on success, persists the resulting
  /// session exactly like signInWithGoogleBackend() — same
  /// TokenStorage.save()/backendSession.markAuthenticated() calls, so
  /// downstream code can't tell the two sign-in methods apart.
  ///
  /// Throws [ApiException] on any failure. The backend returns the SAME
  /// generic 401 for a wrong code, an expired code, an already-used code,
  /// or no such code at all — this method does not and cannot distinguish
  /// those cases either; show one generic "invalid or expired code"
  /// message to the user regardless of [ApiException.message].
  Future<void> verifyOtpBackend(
      {required String phoneNumber, required String code}) async {
    _backendLoading = true;
    notifyListeners();
    try {
      final response = await ApiClient.instance.post(
        '/auth/phone/verify-otp',
        body: {'phoneNumber': phoneNumber, 'code': code},
      );
      final session = response['session'] as Map<String, dynamic>;
      await TokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );
      backendSession.markAuthenticated();
      await refreshCurrentUser();
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
