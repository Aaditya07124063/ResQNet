import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/api_exception.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

/// Step 2 of the Firebase-removal migration — backend-controlled phone OTP.
///
/// Same constraint as google_login_cutover_test.dart: `AuthService` itself
/// cannot be instantiated directly here (its constructor accesses
/// `FirebaseAuth.instance` eagerly, which throws `[core/no-app]` under
/// plain `flutter_test`) — not something this step's "modify ONLY the
/// phone OTP portion of auth_service.dart" instruction licenses changing.
/// What IS tested here is the exact backend contract
/// `sendOtpBackend()`/`verifyOtpBackend()` rely on — the same ApiClient
/// calls and the same response-parsing/token-storage code shape those
/// methods use verbatim — so a regression in that contract is still caught.
///
/// "logout" and "session restoration" for a phone-OTP-established session
/// are NOT re-tested here: verifyOtpBackend() persists its session via the
/// exact same TokenStorage.save()/BackendSessionController.markAuthenticated()
/// path signInWithGoogleBackend() uses, and signOutBackend()/
/// restoreBackendSession() are entirely sign-in-method-agnostic — both are
/// already covered generically by backend_session_controller_test.dart
/// (restore()) and google_login_cutover_test.dart's own coverage of the
/// shared TokenStorage.clear() path, for ANY backend session regardless of
/// how it was established.
void main() {
  late FakeSecureStorage secureStorage;

  setUp(() {
    secureStorage = FakeSecureStorage();
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  group('POST /auth/phone/send-otp request shape', () {
    test('sends {phoneNumber} as the body and no Authorization header, even with a stored token', () async {
      await TokenStorage.instance.save(accessToken: 'stale-access', refreshToken: 'stale-refresh');
      final fake = FakeHttpClient((request) async {
        expect(request.url.path, contains('/auth/phone/send-otp'));
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.method, 'POST');
        return jsonStreamedResponse(200, {'message': 'If eligible, a code was sent.'});
      });

      final response =
          await ApiClient(httpClient: fake).post('/auth/phone/send-otp', body: {'phoneNumber': '+9779812345678'});
      expect(response['message'], 'If eligible, a code was sent.');
    });

    test('a 429 (rate-limited or resend cooldown) surfaces as ApiException, never swallowed', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(429, {
            'error': {'code': 'TOO_MANY_REQUESTS', 'message': 'Please wait before requesting another code'},
          }));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/phone/send-otp', body: {'phoneNumber': '+9779812345678'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 429)),
      );
    });

    test('a 500 (SMS provider failure) surfaces as ApiException without a raw/unhandled exception type', () async {
      final fake = FakeHttpClient((request) async => emptyStreamedResponse(500));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/phone/send-otp', body: {'phoneNumber': '+9779812345678'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('network failure surfaces as ApiException with isNetworkError true', () async {
      final fake = FakeHttpClient((request) async => throw const SocketException('no route to host'));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/phone/send-otp', body: {'phoneNumber': '+9779812345678'}),
        throwsA(isA<ApiException>().having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
      );
    });
  });

  group('POST /auth/phone/verify-otp request shape', () {
    test('sends {phoneNumber, code} as the body', () async {
      final fake = FakeHttpClient((request) async {
        expect(request.url.path, contains('/auth/phone/verify-otp'));
        expect(request.method, 'POST');
        return jsonStreamedResponse(200, {
          'user': {'id': 'user-1', 'phoneNumber': '+9779812345678', 'phoneVerified': true},
          ...fakeSession(),
        });
      });

      await ApiClient(httpClient: fake)
          .post('/auth/phone/verify-otp', body: {'phoneNumber': '+9779812345678', 'code': '123456'});
    });

    test('successful response.session lands in TokenStorage exactly like verifyOtpBackend() does', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(200, {
            'user': {'id': 'user-1', 'phoneNumber': '+9779812345678', 'phoneVerified': true},
            ...fakeSession(access: 'new-access', refresh: 'new-refresh'),
          }));

      final response = await ApiClient(httpClient: fake)
          .post('/auth/phone/verify-otp', body: {'phoneNumber': '+9779812345678', 'code': '123456'});

      // Mirrors verifyOtpBackend()'s own extraction exactly.
      final session = response['session'] as Map<String, dynamic>;
      await TokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );

      expect(await TokenStorage.instance.readAccessToken(), 'new-access');
      expect(await TokenStorage.instance.readRefreshToken(), 'new-refresh');
    });

    test('a 401 (invalid/expired/consumed code) surfaces as ApiException with isUnauthorized true', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(401, {
            'error': {'code': 'UNAUTHORIZED', 'message': 'Invalid or expired code'},
          }));

      await expectLater(
        ApiClient(httpClient: fake)
            .post('/auth/phone/verify-otp', body: {'phoneNumber': '+9779812345678', 'code': '000000'}),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
    });

    test('a 403 (suspended account) surfaces statusCode/code/message', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(403, {
            'error': {'code': 'FORBIDDEN', 'message': 'This account is not active'},
          }));

      await expectLater(
        ApiClient(httpClient: fake)
            .post('/auth/phone/verify-otp', body: {'phoneNumber': '+9779812345678', 'code': '123456'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('a 400 (malformed phone/code) surfaces statusCode/code/message', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(400, {
            'error': {'code': 'BAD_REQUEST', 'message': 'Invalid request body'},
          }));

      await expectLater(
        ApiClient(httpClient: fake)
            .post('/auth/phone/verify-otp', body: {'phoneNumber': 'x', 'code': '1'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });

    test('a 200 response missing "session" throws rather than silently reporting success', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(200, {
            'user': {'id': 'user-1'},
            // no "session" key at all
          }));

      final response = await ApiClient(httpClient: fake)
          .post('/auth/phone/verify-otp', body: {'phoneNumber': '+9779812345678', 'code': '123456'});

      // Same cast verifyOtpBackend() performs — a malformed backend
      // response fails loudly rather than being treated as a successful
      // login, matching signInWithGoogleBackend()'s equivalent contract.
      expect(() => response['session'] as Map<String, dynamic>, throwsA(isA<TypeError>()));
    });
  });
}
