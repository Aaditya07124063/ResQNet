import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/api_exception.dart';
import 'package:resqnet/core/network/backend_session.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() {
    secureStorage = FakeSecureStorage();
  });

  tearDown(() {
    secureStorage.dispose();
    // Reset the singleton in case a test (e.g. the BackendSession group)
    // swapped it for a fake-backed instance — never let that leak into
    // a later test.
    ApiClient.instance = ApiClient();
  });

  group('normal authenticated requests', () {
    test('attaches the stored access token and returns normally on 200', () async {
      await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
      final fake = FakeHttpClient((request) async {
        expect(request.headers['Authorization'], 'Bearer access-1');
        return jsonStreamedResponse(200, {'ok': true});
      });

      final client = ApiClient(httpClient: fake);
      final result = await client.get('/profile', auth: true);

      expect(result, {'ok': true});
      expect(fake.requests, hasLength(1));
    });

    test('an unauthenticated (auth: false) request never attaches a token', () async {
      await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
      final fake = FakeHttpClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return jsonStreamedResponse(200, {'ok': true});
      });

      await ApiClient(httpClient: fake).post('/auth/google', body: {'idToken': 'x'}, auth: false);
    });
  });

  group('401 triggers exactly one refresh and one retry', () {
    test('a 401 is followed by a refresh, then the original request succeeds using the new token', () async {
      await TokenStorage.instance.save(accessToken: 'expired-access', refreshToken: 'refresh-1');
      final resourceCalls = <String?>[];

      final fake = FakeHttpClient((request) async {
        if (request.url.path.contains('/auth/refresh')) {
          return jsonStreamedResponse(200, fakeSession(access: 'new-access', refresh: 'new-refresh'));
        }
        resourceCalls.add(request.headers['Authorization']);
        if (resourceCalls.length == 1) {
          return jsonStreamedResponse(401, {
            'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
          });
        }
        return jsonStreamedResponse(200, {'ok': true});
      });

      final client = ApiClient(httpClient: fake);
      final result = await client.get('/profile', auth: true);

      expect(result, {'ok': true});
      expect(resourceCalls, ['Bearer expired-access', 'Bearer new-access']);
      expect(
        fake.requests.where((r) => r.url.path.contains('/auth/refresh')),
        hasLength(1),
        reason: 'refresh must be called exactly once',
      );
      expect(await TokenStorage.instance.readAccessToken(), 'new-access');
      expect(await TokenStorage.instance.readRefreshToken(), 'new-refresh');
    });

    test('refresh POST uses the stored refresh token, not a bearer header', () async {
      await TokenStorage.instance.save(accessToken: 'expired-access', refreshToken: 'the-refresh-token');
      var resourceCallCount = 0;

      final fake = FakeHttpClient((request) async {
        if (request.url.path.contains('/auth/refresh')) {
          expect(request.headers.containsKey('Authorization'), isFalse);
          return jsonStreamedResponse(200, fakeSession());
        }
        resourceCallCount++;
        return resourceCallCount == 1
            ? jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'x'}})
            : jsonStreamedResponse(200, {'ok': true});
      });

      await ApiClient(httpClient: fake).get('/profile', auth: true);
    });

    test('refresh failure clears the local session and surfaces the original 401 safely', () async {
      await TokenStorage.instance.save(accessToken: 'expired-access', refreshToken: 'bad-refresh');

      final fake = FakeHttpClient((request) async {
        if (request.url.path.contains('/auth/refresh')) {
          return jsonStreamedResponse(401, {
            'error': {'code': 'UNAUTHORIZED', 'message': 'Invalid or expired refresh token'},
          });
        }
        return jsonStreamedResponse(401, {
          'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
        });
      });

      final client = ApiClient(httpClient: fake);

      await expectLater(
        client.get('/profile', auth: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
      expect(await TokenStorage.instance.readAccessToken(), isNull);
      expect(await TokenStorage.instance.readRefreshToken(), isNull);
    });

    test('never retries more than once, even if the resource keeps returning 401 after a successful refresh', () async {
      await TokenStorage.instance.save(accessToken: 'expired-access', refreshToken: 'refresh-1');
      var resourceCallCount = 0;

      final fake = FakeHttpClient((request) async {
        if (request.url.path.contains('/auth/refresh')) {
          return jsonStreamedResponse(200, fakeSession(access: 'new-access', refresh: 'new-refresh'));
        }
        resourceCallCount++;
        // Always 401, even after the refresh handed over a "new" token —
        // this must not spin forever.
        return jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'still bad'}});
      });

      final client = ApiClient(httpClient: fake);

      await expectLater(client.get('/profile', auth: true), throwsA(isA<ApiException>()));
      expect(resourceCallCount, 2, reason: 'original attempt + exactly one retry, never more');
      expect(
        fake.requests.where((r) => r.url.path.contains('/auth/refresh')),
        hasLength(1),
        reason: 'a second 401 (on the retry) must not trigger a second refresh',
      );
    });

    test('a missing refresh token short-circuits without any network refresh call', () async {
      // No TokenStorage.save() at all — simulates a device with no stored
      // session (e.g. a stale/expired access token was cached somewhere
      // but the refresh token was never persisted or was already cleared).
      final fake = FakeHttpClient((request) async {
        expect(request.url.path.contains('/auth/refresh'), isFalse);
        return jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'no session'}});
      });

      await expectLater(
        ApiClient(httpClient: fake).get('/profile', auth: true),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('single-flight refresh under concurrency', () {
    test('several concurrent 401s trigger only ONE refresh call, and all requests succeed with the new token', () async {
      await TokenStorage.instance.save(accessToken: 'expired-access', refreshToken: 'refresh-1');
      final attemptCounts = <String, int>{'/a': 0, '/b': 0, '/c': 0};

      final fake = FakeHttpClient((request) async {
        if (request.url.path.contains('/auth/refresh')) {
          return jsonStreamedResponse(200, fakeSession(access: 'new-access', refresh: 'new-refresh'));
        }
        final path = '/${request.url.path.split('/').last}';
        attemptCounts[path] = (attemptCounts[path] ?? 0) + 1;
        if (attemptCounts[path] == 1) {
          // A small delay so all three requests reach their own 401
          // before any single one of them finishes refreshing+retrying —
          // this is what actually exercises the concurrent path rather
          // than three sequential single-request refresh cycles.
          await Future.delayed(const Duration(milliseconds: 5));
          return jsonStreamedResponse(401, {'error': {'code': 'UNAUTHORIZED', 'message': 'expired'}});
        }
        expect(request.headers['Authorization'], 'Bearer new-access');
        return jsonStreamedResponse(200, {'path': path});
      });

      final client = ApiClient(httpClient: fake);
      final results = await Future.wait([
        client.get('/a', auth: true),
        client.get('/b', auth: true),
        client.get('/c', auth: true),
      ]);

      expect(results.map((r) => r['path']), containsAll(['/a', '/b', '/c']));
      expect(
        fake.requests.where((r) => r.url.path.contains('/auth/refresh')),
        hasLength(1),
        reason: 'three concurrent 401s must produce exactly one refresh request',
      );
      expect(await TokenStorage.instance.readAccessToken(), 'new-access');
    });
  });

  group('logout clears the backend session', () {
    test('postNoContent to /auth/logout succeeds and the caller still clears local tokens', () async {
      await TokenStorage.instance.save(accessToken: 'access-1', refreshToken: 'refresh-1');
      final fake = FakeHttpClient((request) async => emptyStreamedResponse(204));

      await ApiClient(httpClient: fake).postNoContent(
        '/auth/logout',
        body: {'refreshToken': 'refresh-1'},
        auth: true,
      );
      await TokenStorage.instance.clear();

      expect(await TokenStorage.instance.readAccessToken(), isNull);
      expect(await TokenStorage.instance.readRefreshToken(), isNull);
    });
  });

  group('BackendSession.restore (startup session restoration)', () {
    test('no stored session at all -> not authenticated, no network call', () async {
      final fake = FakeHttpClient((request) async {
        fail('must not make a network call when there is no session at all');
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      expect(await BackendSession.restore(), isFalse);
    });

    test('a still-valid stored access token -> authenticated, no network call needed', () async {
      final validToken = _jwtExpiringIn(const Duration(minutes: 10));
      await TokenStorage.instance.save(accessToken: validToken, refreshToken: 'refresh-1');
      final fake = FakeHttpClient((request) async {
        fail('must not refresh when the access token is still locally valid');
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      expect(await BackendSession.restore(), isTrue);
    });

    test('an expired access token with a valid refresh token -> restores via exactly one refresh', () async {
      final expiredToken = _jwtExpiringIn(const Duration(minutes: -10));
      await TokenStorage.instance.save(accessToken: expiredToken, refreshToken: 'refresh-1');
      var refreshCalls = 0;
      final fake = FakeHttpClient((request) async {
        refreshCalls++;
        return jsonStreamedResponse(200, fakeSession(access: 'new-access', refresh: 'new-refresh'));
      });
      ApiClient.instance = ApiClient(httpClient: fake);

      expect(await BackendSession.restore(), isTrue);
      expect(refreshCalls, 1);
      expect(await TokenStorage.instance.readAccessToken(), 'new-access');
    });

    test('an expired access token with an invalid refresh token -> not authenticated, session cleared', () async {
      final expiredToken = _jwtExpiringIn(const Duration(minutes: -10));
      await TokenStorage.instance.save(accessToken: expiredToken, refreshToken: 'bad-refresh');
      final fake = FakeHttpClient(
        (request) async => jsonStreamedResponse(401, {
          'error': {'code': 'UNAUTHORIZED', 'message': 'invalid refresh token'},
        }),
      );
      ApiClient.instance = ApiClient(httpClient: fake);

      expect(await BackendSession.restore(), isFalse);
      expect(await TokenStorage.instance.readAccessToken(), isNull);
      expect(await TokenStorage.instance.readRefreshToken(), isNull);
    });
  });
}

/// Minimal inline JWT builder (mirrors test/jwt_utils_test.dart's helper —
/// duplicated locally to keep this file self-contained).
String _jwtExpiringIn(Duration delta) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final header = encode({'alg': 'HS256', 'typ': 'JWT'});
  final payload = encode({
    'sub': 'user-1',
    'exp': DateTime.now().add(delta).millisecondsSinceEpoch ~/ 1000,
  });
  return '$header.$payload.fake-signature';
}
