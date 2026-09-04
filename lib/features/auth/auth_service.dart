import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/token_storage.dart';

class AuthService extends ChangeNotifier {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

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

  // Google Sign In
  Future<bool> signInWithGoogle() async {
    _isLoading = true;
    notifyListeners();
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        _isLoading = false;
        notifyListeners();
        return false;
      }
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      await _auth.signInWithCredential(credential);
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // Sign Out
  Future<void> signOut() async {
    await _auth.signOut();
    await _googleSignIn.signOut();
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

  Future<bool> isBackendSignedIn() async =>
      (await TokenStorage.instance.readAccessToken()) != null;

  /// Signs in against the ResQNet backend using a Google ID token. Returns
  /// true on success. Throws [ApiException] on failure (including
  /// [ApiException.isNetworkError] when the backend can't be reached at
  /// all) so callers can distinguish "backend rejected this" from
  /// "backend isn't reachable right now" rather than treating both as a
  /// generic failure.
  Future<bool> signInWithGoogleBackend() async {
    _backendLoading = true;
    notifyListeners();
    try {
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return false;

      final googleAuth = await googleUser.authentication;
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