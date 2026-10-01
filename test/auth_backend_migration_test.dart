import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resqnet/app.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/backend_session_controller.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'package:resqnet/features/auth/auth_service.dart';
import 'package:resqnet/core/models/emergency_outbox_entry.dart';
import 'package:resqnet/core/services/communication_service.dart';
import 'package:resqnet/core/services/emergency_outbox_store.dart';
import 'package:resqnet/core/services/profile_service.dart';
import 'package:resqnet/core/services/trusted_contacts_service.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

String jwt({required String sub, required Duration expiresIn}) {
  String part(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = DateTime.now().add(expiresIn).millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.${part({'sub': sub, 'exp': exp})}.signature';
}

Map<String, dynamic> sessionJson(String access, String refresh) => {
      'session': {
        'accessToken': access,
        'accessTokenExpiresAt': DateTime.now().add(const Duration(minutes: 15)).toIso8601String(),
        'refreshToken': refresh,
        'refreshTokenExpiresAt': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      },
    };

const me = {
  'user': {'id': 'user-1', 'displayName': 'Asha', 'email': 'asha@example.com', 'phoneNumber': '+9779812345678'},
};

/// Mocks the google_sign_in plugin channel (no real Google account).
class FakeGoogleSignInChannel {
  FakeGoogleSignInChannel({this.idToken = 'google-id-token', this.cancel = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'signIn':
          return cancel ? null : {'email': 'asha@example.com', 'id': 'google-sub', 'displayName': 'Asha'};
        case 'getTokens':
          return {'idToken': idToken, 'accessToken': 'google-access'};
        default:
          return null;
      }
    });
  }

  static const _channel = MethodChannel('plugins.flutter.io/google_sign_in');
  final String? idToken;
  final bool cancel;
  final List<String> calls = [];

  void dispose() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
}

void main() {
  late FakeSecureStorage secureStorage;
  late List<http.Request> requests;

  void backend(Future<http.StreamedResponse> Function(http.Request r) respond) {
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient((request) async {
      final r = request as http.Request;
      requests.add(r);
      return respond(r);
    }));
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    secureStorage = FakeSecureStorage();
    requests = [];
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  test('AuthService is constructed without any Firebase initialization', () {
    // Before the migration this threw [core/no-app] (FirebaseAuth.instance).
    final auth = AuthService();
    expect(auth.isLoggedIn, isFalse);
    expect(auth.currentUser, isNull);
  });

  group('backend session decides authentication', () {
    test('no stored session: signed out, no network call', () async {
      backend((_) async => fail('no request expected'));
      final auth = AuthService();
      expect(await auth.restoreBackendSession(), isFalse);
      expect(auth.backendSession.status, BackendSessionStatus.unauthenticated);
      expect(requests, isEmpty);
    });

    test('a valid stored session: signed in and the user is loaded from /me', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'user-1', expiresIn: const Duration(minutes: 10)), refreshToken: 'r');
      backend((r) async => jsonStreamedResponse(200, me));
      final auth = AuthService();

      expect(await auth.restoreBackendSession(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.displayName, 'Asha');
      expect(await auth.currentSenderId(), 'user-1');
      expect(requests.single.url.path, '/api/v1/me');
    });

    test('app restart while offline with an expired access token stays signed in (tokens kept)', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'user-1', expiresIn: const Duration(minutes: -5)), refreshToken: 'r');
      backend((_) async => throw const SocketException('Failed host lookup: api.resqnet.co'));
      final auth = AuthService();

      expect(await auth.restoreBackendSession(), isTrue);
      expect(await TokenStorage.instance.readRefreshToken(), 'r');
    });

    test('a rejected refresh ends the session and signs the user out', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'user-1', expiresIn: const Duration(minutes: 10)), refreshToken: 'revoked');
      backend((r) async => r.url.path.endsWith('/me')
          ? jsonStreamedResponse(200, me)
          : jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'no'}}));
      final auth = AuthService();
      await auth.restoreBackendSession();
      expect(auth.isLoggedIn, isTrue);

      // Mid-session: the access token is rejected and the refresh fails.
      await expectLater(ApiClient.instance.get('/profile'), throwsA(anything));

      expect(auth.isLoggedIn, isFalse);
      expect(auth.currentUser, isNull);
      expect(await TokenStorage.instance.readRefreshToken(), isNull);
    });

    test('the auth gate maps backend session state to screens', () {
      const loading = Text('loading'), home = Text('home'), login = Text('login');
      Widget screen(BackendSessionStatus s) => authGateScreenFor(s, loading: loading, signedIn: home, signedOut: login);
      expect(screen(BackendSessionStatus.unknown), loading);
      expect(screen(BackendSessionStatus.restoring), loading);
      expect(screen(BackendSessionStatus.authenticated), home);
      expect(screen(BackendSessionStatus.unauthenticated), login);
    });
  });

  group('logout', () {
    test('revokes the refresh token and clears the backend session', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'user-1', expiresIn: const Duration(minutes: 10)), refreshToken: 'r1');
      final google = FakeGoogleSignInChannel();
      backend((r) async => r.url.path.endsWith('/me') ? jsonStreamedResponse(200, me) : emptyStreamedResponse(204));
      final auth = AuthService();
      await auth.restoreBackendSession();

      await auth.signOut();

      final logout = requests.singleWhere((r) => r.url.path == '/api/v1/auth/logout');
      expect(jsonDecode(logout.body), {'refreshToken': 'r1'});
      expect(await TokenStorage.instance.readAccessToken(), isNull);
      expect(auth.backendSession.status, BackendSessionStatus.unauthenticated);
      expect(auth.currentUser, isNull);
      google.dispose();
    });

    test('signing out resets the medical-sharing opt-in to OFF for the next person', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'u', expiresIn: const Duration(minutes: 10)), refreshToken: 'r1');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(ProfileService.includeMedicalInAutoSosKey, true);
      final google = FakeGoogleSignInChannel();
      backend((_) async => emptyStreamedResponse(204));

      await AuthService().signOut();

      expect(prefs.getBool(ProfileService.includeMedicalInAutoSosKey), isNull);
      final next = ProfileService();
      await next.loadMedicalSharingPreference();
      expect(next.includeMedicalInAutoSos, isFalse);
      google.dispose();
    });

    test('removes the signed-in user\'s cached personal data but keeps the SOS outbox', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'u', expiresIn: const Duration(minutes: 10)), refreshToken: 'r1');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(ProfileService.storageKey, '{"bloodGroup":"O+","allergies":"penicillin"}');
      await prefs.setString(TrustedContactsService.storageKey, '[]');
      await prefs.setString(CommunicationService.outboxKey, '[]');
      await prefs.setString('unrelated_setting', 'kept');
      await EmergencyOutboxStore.instance.upsert(EmergencyOutboxEntry(
        eventId: 'sos-1',
        eventSource: 'manual',
        category: 'medical',
        createdAt: DateTime.now(),
        state: OutboxEntryState.queued,
      ));
      final google = FakeGoogleSignInChannel();
      backend((_) async => emptyStreamedResponse(204));

      await AuthService().signOut();

      for (final key in [ProfileService.storageKey, TrustedContactsService.storageKey, CommunicationService.outboxKey]) {
        expect(prefs.getString(key), isNull, reason: key);
      }
      expect(prefs.getString('unrelated_setting'), 'kept');
      // Emergency delivery never depends on being signed in.
      expect(await EmergencyOutboxStore.instance.get('sos-1'), isNotNull);
      google.dispose();
    });

    test('still signs out locally when the server cannot be reached', () async {
      await TokenStorage.instance.save(accessToken: jwt(sub: 'u', expiresIn: const Duration(minutes: 10)), refreshToken: 'r1');
      final google = FakeGoogleSignInChannel();
      backend((_) async => throw const SocketException('offline'));
      final auth = AuthService();

      await auth.signOut();

      expect(await TokenStorage.instance.readRefreshToken(), isNull);
      expect(auth.isLoggedIn, isFalse);
      google.dispose();
    });
  });

  group('Google sign-in through the ResQNet backend', () {
    test('exchanges the Google ID token at /auth/google and stores the ResQNet session', () async {
      final google = FakeGoogleSignInChannel();
      backend((r) async => r.url.path.endsWith('/auth/google')
          ? jsonStreamedResponse(200, sessionJson(jwt(sub: 'user-1', expiresIn: const Duration(minutes: 15)), 'r'))
          : jsonStreamedResponse(200, me));
      final auth = AuthService();

      expect(await auth.signInWithGoogleBackend(), isTrue);

      final login = requests.firstWhere((r) => r.url.path == '/api/v1/auth/google');
      expect(jsonDecode(login.body), {'idToken': 'google-id-token'});
      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.id, 'user-1');
      expect(await TokenStorage.instance.readRefreshToken(), 'r');
      google.dispose();
    });

    test('cancelling the Google account picker is not an error and signs nobody in', () async {
      final google = FakeGoogleSignInChannel(cancel: true);
      backend((_) async => fail('no backend call expected'));
      final auth = AuthService();
      expect(await auth.signInWithGoogleBackend(), isFalse);
      expect(auth.isLoggedIn, isFalse);
      google.dispose();
    });
  });

  group('phone OTP through the ResQNet backend', () {
    test('send-otp then verify-otp stores the ResQNet session', () async {
      backend((r) async {
        if (r.url.path.endsWith('/send-otp')) return jsonStreamedResponse(200, {'message': 'If eligible, a code was sent.'});
        if (r.url.path.endsWith('/verify-otp')) {
          return jsonStreamedResponse(200, sessionJson(jwt(sub: 'user-1', expiresIn: const Duration(minutes: 15)), 'r'));
        }
        return jsonStreamedResponse(200, me);
      });
      final auth = AuthService();

      await auth.sendOtpBackend('+9779812345678');
      await auth.verifyOtpBackend(phoneNumber: '+9779812345678', code: '123456');

      expect(requests[0].url.path, '/api/v1/auth/phone/send-otp');
      expect(jsonDecode(requests[0].body), {'phoneNumber': '+9779812345678'});
      expect(requests[1].url.path, '/api/v1/auth/phone/verify-otp');
      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentUser?.phoneNumber, '+9779812345678');
    });

    test('a wrong code leaves the user signed out', () async {
      backend((_) async => jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'Invalid or expired code'}}));
      final auth = AuthService();
      await expectLater(auth.verifyOtpBackend(phoneNumber: '+9779812345678', code: '000000'), throwsA(anything));
      expect(auth.isLoggedIn, isFalse);
      expect(await TokenStorage.instance.readAccessToken(), isNull);
    });
  });
}
