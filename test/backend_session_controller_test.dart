import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:resqnet/core/network/api_client.dart';
import 'package:resqnet/core/network/backend_session_controller.dart';
import 'package:resqnet/core/network/token_storage.dart';
import 'support/fake_http_client.dart';
import 'support/fake_secure_storage.dart';

/// Fails the test immediately if the backend restoration flow ever hits
/// POST /auth/google — restoring/refreshing an existing session must
/// never attempt a fresh Google sign-in round trip.
Future<http.StreamedResponse> _rejectGoogleSignIn(http.BaseRequest request) async {
  if (request.url.path.contains('/auth/google')) {
    fail('backend session restoration must never call /auth/google');
  }
  return jsonStreamedResponse(401, {
    'error': {'code': 'UNAUTHORIZED', 'message': 'unexpected call'},
  });
}

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

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() {
    secureStorage = FakeSecureStorage();
  });

  tearDown(() {
    secureStorage.dispose();
    ApiClient.instance = ApiClient();
  });

  test('initial status is unknown before restore() is ever called', () {
    expect(BackendSessionController().status, BackendSessionStatus.unknown);
  });

  test('restore() with no stored session -> unauthenticated, no network call at all', () async {
    ApiClient.instance = ApiClient(
      httpClient: FakeHttpClient((request) async {
        fail('must not make any network call when there is no session at all');
      }),
    );

    final controller = BackendSessionController();
    final seen = <BackendSessionStatus>[];
    controller.addListener(() => seen.add(controller.status));

    await controller.restore();

    expect(controller.status, BackendSessionStatus.unauthenticated);
    expect(seen, [BackendSessionStatus.restoring, BackendSessionStatus.unauthenticated]);
  });

  test('restore() with a still-valid access token -> authenticated, no network call needed', () async {
    await TokenStorage.instance.save(
      accessToken: _jwtExpiringIn(const Duration(minutes: 10)),
      refreshToken: 'refresh-1',
    );
    ApiClient.instance = ApiClient(httpClient: FakeHttpClient(_rejectGoogleSignIn));

    final controller = BackendSessionController();
    await controller.restore();

    expect(controller.status, BackendSessionStatus.authenticated);
  });

  test('restore() with an expired access token + valid refresh -> authenticated via exactly one refresh call, never /auth/google', () async {
    await TokenStorage.instance.save(
      accessToken: _jwtExpiringIn(const Duration(minutes: -5)),
      refreshToken: 'refresh-1',
    );
    var refreshCalls = 0;
    final fake = FakeHttpClient((request) async {
      if (request.url.path.contains('/auth/google')) {
        fail('backend session restoration must never call /auth/google');
      }
      expect(request.url.path.contains('/auth/refresh'), isTrue);
      refreshCalls++;
      return jsonStreamedResponse(200, fakeSession(access: 'new-access', refresh: 'new-refresh'));
    });
    ApiClient.instance = ApiClient(httpClient: fake);

    final controller = BackendSessionController();
    await controller.restore();

    expect(controller.status, BackendSessionStatus.authenticated);
    expect(refreshCalls, 1);
    expect(await TokenStorage.instance.readAccessToken(), 'new-access');
  });

  test('restore() with an expired access token + failing refresh -> unauthenticated, session cleared', () async {
    await TokenStorage.instance.save(
      accessToken: _jwtExpiringIn(const Duration(minutes: -5)),
      refreshToken: 'bad-refresh',
    );
    final fake = FakeHttpClient(
      (request) async => jsonStreamedResponse(401, {
        'error': {'code': 'UNAUTHORIZED', 'message': 'invalid refresh token'},
      }),
    );
    ApiClient.instance = ApiClient(httpClient: fake);

    final controller = BackendSessionController();
    await controller.restore();

    expect(controller.status, BackendSessionStatus.unauthenticated);
    expect(await TokenStorage.instance.readAccessToken(), isNull);
    expect(await TokenStorage.instance.readRefreshToken(), isNull);
  });

  test('a second restore() call while one is already in flight is a no-op', () async {
    await TokenStorage.instance.save(
      accessToken: _jwtExpiringIn(const Duration(minutes: -5)),
      refreshToken: 'refresh-1',
    );
    var refreshCalls = 0;
    final fake = FakeHttpClient((request) async {
      refreshCalls++;
      // Small delay so the second, synchronous restore() call below is
      // guaranteed to observe `restoring` before this one settles.
      await Future.delayed(const Duration(milliseconds: 5));
      return jsonStreamedResponse(200, fakeSession());
    });
    ApiClient.instance = ApiClient(httpClient: fake);

    final controller = BackendSessionController();
    final first = controller.restore();
    final second = controller.restore(); // should return immediately, no-op
    await Future.wait([first, second]);

    expect(refreshCalls, 1, reason: 'only one restoration attempt should ever run concurrently');
  });

  test('markAuthenticated() sets authenticated directly and notifies listeners, no network call', () {
    ApiClient.instance = ApiClient(
      httpClient: FakeHttpClient((request) async {
        fail('markAuthenticated() must not make any network call — the caller '
            'already completed login and saved tokens before calling this');
      }),
    );
    final controller = BackendSessionController();
    var notified = false;
    controller.addListener(() => notified = true);

    controller.markAuthenticated();

    expect(controller.status, BackendSessionStatus.authenticated);
    expect(notified, isTrue);
  });

  test('markSignedOut() sets unauthenticated directly and notifies listeners', () {
    final controller = BackendSessionController();
    var notified = false;
    controller.addListener(() => notified = true);

    controller.markSignedOut();

    expect(controller.status, BackendSessionStatus.unauthenticated);
    expect(notified, isTrue);
  });
}
