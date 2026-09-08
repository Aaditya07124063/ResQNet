import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'api_exception.dart';
import 'token_storage.dart';

/// Thin HTTP client for the ResQNet backend.
///
/// Every call goes through HTTPS in staging/production (see ApiConfig);
/// nothing here ever logs a token or request body containing secrets.
///
/// Phase 4A: adds automatic refresh-on-401 for authenticated requests. The
/// backend rotates refresh tokens (a token is invalidated the moment it's
/// used), so if several requests hit a 401 at once, only ONE refresh call
/// is ever made — every waiting request shares that same in-flight
/// Future and then retries with the resulting new access token. A
/// request is retried at most once; if the refresh itself fails, the
/// local session is cleared and the original 401 is surfaced.
class ApiClient {
  ApiClient({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  /// Not `final` so tests can substitute a fake-backed instance (e.g. for
  /// BackendSession.restore(), which calls through this singleton) —
  /// production code always uses the real client created here.
  static ApiClient instance = ApiClient();

  final http.Client _httpClient;
  static const _timeout = Duration(seconds: 15);

  /// Guards concurrent refresh attempts — see the class doc comment.
  /// Cleared once the in-flight refresh settles (success or failure) so a
  /// later, separate 401 can trigger a fresh refresh cycle.
  Future<bool>? _refreshFuture;

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
  }) => _send('POST', path, body: body, auth: auth);

  Future<Map<String, dynamic>> get(String path, {bool auth = true}) =>
      _send('GET', path, auth: auth);

  Future<Map<String, dynamic>> put(
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) => _send('PUT', path, body: body, auth: auth);

  Future<Map<String, dynamic>> patch(
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) => _send('PATCH', path, body: body, auth: auth);

  Future<void> delete(String path, {bool auth = true}) async {
    await _send('DELETE', path, auth: auth, expectBody: false);
  }

  Future<void> postNoContent(
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
  }) async {
    await _send('POST', path, body: body, auth: auth, expectBody: false);
  }

  /// Sends a raw (non-JSON) request body — e.g. profile-image bytes with
  /// an `image/*` Content-Type, matching `profileImageRoutes.ts`'s
  /// `express.raw({type: 'image/*'})` route exactly (see
  /// backend/src/routes/profileImageRoutes.ts). Distinct from `_send`
  /// because that method always JSON-encodes `body`.
  Future<Map<String, dynamic>> putBytes(
    String path, {
    required List<int> bytes,
    required String contentType,
    bool auth = true,
  }) => _send('PUT', path, auth: auth, rawBody: bytes, contentType: contentType);

  /// Attempts to refresh the backend session right now (e.g. at app
  /// startup). Shares the same single-flight guard as the automatic
  /// 401-triggered refresh below, so calling this explicitly can never
  /// race with — or duplicate — a refresh a concurrent request happens to
  /// be triggering at the same moment.
  Future<bool> refreshSession() => _refreshSession();

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    List<int>? rawBody,
    String? contentType,
    bool auth = false,
    bool expectBody = true,
    bool isRetryAfterRefresh = false,
  }) async {
    final uri = ApiConfig.resolve(path);
    final headers = {'Content-Type': contentType ?? 'application/json'};

    if (auth) {
      final token = await TokenStorage.instance.readAccessToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (rawBody != null) {
        request.bodyBytes = rawBody;
      } else {
        request.body = body != null ? jsonEncode(body) : '';
      }
      final streamed = await _httpClient.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed);
    } on SocketException {
      throw ApiException.network('No connection to the ResQNet server');
    } on HttpException {
      throw ApiException.network('Could not reach the ResQNet server');
    } catch (e) {
      throw ApiException.network('Network request failed: $e');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (!expectBody || response.body.isEmpty) return const {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    // Exactly one refresh-and-retry attempt: only for an authenticated
    // request's 401, and never on the retry itself (isRetryAfterRefresh
    // guards that) — this is what makes infinite loops impossible.
    if (response.statusCode == 401 && auth && !isRetryAfterRefresh) {
      final refreshed = await _refreshSession();
      if (refreshed) {
        return _send(
          method,
          path,
          body: body,
          rawBody: rawBody,
          contentType: contentType,
          auth: auth,
          expectBody: expectBody,
          isRetryAfterRefresh: true,
        );
      }
      // Refresh failed — local session already cleared by _performRefresh.
      // Fall through and surface the original 401 below rather than
      // retrying again.
    }

    String code = 'UNKNOWN_ERROR';
    String message = 'Request failed (${response.statusCode})';
    try {
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final error = decoded['error'] as Map<String, dynamic>?;
      if (error != null) {
        code = error['code'] as String? ?? code;
        message = error['message'] as String? ?? message;
      }
    } catch (_) {
      // Non-JSON error body (e.g. a proxy/nginx error page) — keep defaults.
    }
    throw ApiException(statusCode: response.statusCode, code: code, message: message);
  }

  Future<bool> _refreshSession() {
    return _refreshFuture ??= _performRefresh().whenComplete(() => _refreshFuture = null);
  }

  Future<bool> _performRefresh() async {
    final refreshToken = await TokenStorage.instance.readRefreshToken();
    if (refreshToken == null) {
      await TokenStorage.instance.clear();
      return false;
    }
    try {
      // auth: false — the refresh endpoint takes the refresh token in the
      // body, not a bearer header (matches backend/src/routes/authRoutes.ts:
      // POST /auth/refresh has no requireAuth middleware), and this must
      // never itself re-enter the 401-refresh branch above.
      final result = await post('/auth/refresh', body: {'refreshToken': refreshToken});
      final session = result['session'] as Map<String, dynamic>;
      await TokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );
      return true;
    } catch (_) {
      await TokenStorage.instance.clear();
      return false;
    }
  }
}
