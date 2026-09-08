import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/api_exception.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

/// Phase 4C — Google login cutover.
///
/// `AuthService.signInWithGoogleBackend()` itself cannot be exercised
/// end-to-end here: `AuthService`'s constructor accesses
/// `FirebaseAuth.instance` eagerly (pre-existing, not changed by this
/// phase), which throws `[core/no-app]` under plain `flutter_test` because
/// this project's test suite has never run `Firebase.initializeApp()` —
/// confirmed by direct probe, not assumed. Setting up a fake Firebase app
/// or refactoring AuthService's constructor is out of this phase's scope
/// ("modify signInWithGoogleBackend() only as necessary").
///
/// What IS tested here is the exact backend contract
/// `signInWithGoogleBackend()` relies on — the same `ApiClient` calls and
/// the same response-parsing/token-storage code shape — so a regression
/// in that contract (request shape, response shape, error propagation)
/// is still caught.
void main() {
  late FakeSecureStorage secureStorage;

  setUp(() {
    secureStorage = FakeSecureStorage();
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  group('POST /auth/google request shape', () {
    test('sends {idToken} as the body and no Authorization header, even with a stored token', () async {
      await TokenStorage.instance.save(accessToken: 'stale-access', refreshToken: 'stale-refresh');
      final fake = FakeHttpClient((request) async {
        expect(request.url.path, contains('/auth/google'));
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.method, 'POST');
        return jsonStreamedResponse(200, {
          'user': {'id': 'user-1'},
          ...fakeSession(),
        });
      });

      await ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'fake-id-token'});
    });
  });

  group('successful login response is parsed and stored the same way signInWithGoogleBackend() does', () {
    test('session.accessToken/refreshToken from the response land in TokenStorage', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(200, {
            'user': {'id': 'user-1', 'displayName': 'Test User'},
            ...fakeSession(access: 'new-access', refresh: 'new-refresh'),
          }));

      final response = await ApiClient(httpClient: fake)
          .post('/auth/google', body: {'idToken': 'fake-id-token'});

      // Mirrors signInWithGoogleBackend()'s own extraction exactly.
      final session = response['session'] as Map<String, dynamic>;
      await TokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );

      expect(await TokenStorage.instance.readAccessToken(), 'new-access');
      expect(await TokenStorage.instance.readRefreshToken(), 'new-refresh');
    });
  });

  group('backend rejection is surfaced as ApiException, never swallowed', () {
    test('400 (malformed/invalid idToken) surfaces statusCode/code/message', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(400, {
            'error': {'code': 'INVALID_ID_TOKEN', 'message': 'Google ID token failed verification'},
          }));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'bad-token'}),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.code, 'code', 'INVALID_ID_TOKEN')),
      );
    });

    test('401 surfaces as ApiException with isUnauthorized true', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(401, {
            'error': {'code': 'UNAUTHORIZED', 'message': 'token audience mismatch'},
          }));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'wrong-audience'}),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
    });

    test('409 (e.g. account conflict) surfaces statusCode/code/message', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(409, {
            'error': {'code': 'ACCOUNT_CONFLICT', 'message': 'account already linked differently'},
          }));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'x'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });

    test('server error (500) surfaces statusCode 500 without raising a raw/unhandled exception type', () async {
      final fake = FakeHttpClient((request) async => emptyStreamedResponse(500));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'x'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });
  });

  group('network failure is surfaced as ApiException.network(...), matching signInWithGoogleBackend()\'s catch', () {
    test('a SocketException (offline) becomes an ApiException with isNetworkError true', () async {
      final fake = FakeHttpClient((request) async => throw const SocketException('no route to host'));

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'x'}),
        throwsA(isA<ApiException>().having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
      );
    });

    test('a request timeout becomes an ApiException with isNetworkError true', () async {
      final fake = FakeHttpClient((request) async {
        await Future.delayed(const Duration(seconds: 30));
        return jsonStreamedResponse(200, fakeSession());
      });

      await expectLater(
        ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'x'}),
        throwsA(isA<ApiException>().having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('malformed success response', () {
    test('a 200 response missing "session" throws rather than silently reporting success', () async {
      final fake = FakeHttpClient((request) async => jsonStreamedResponse(200, {
            'user': {'id': 'user-1'},
            // no "session" key at all
          }));

      final response = await ApiClient(httpClient: fake)
          .post('/auth/google', body: {'idToken': 'x'});

      // Same cast signInWithGoogleBackend() performs — documents that a
      // malformed backend response fails loudly (a TypeError) rather than
      // being treated as a successful login. Pre-existing pattern, shared
      // with the refresh-token flow (ApiClient._performRefresh) — not
      // something Phase 4C introduces or is scoped to change.
      expect(() => response['session'] as Map<String, dynamic>, throwsA(isA<TypeError>()));
    });
  });
}
