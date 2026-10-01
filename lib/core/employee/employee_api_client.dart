import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../network/api_config.dart';
import '../network/api_exception.dart';
import 'employee_token_storage.dart';

/// HTTP client for the backend's /employee API. Mirrors [ApiClient]'s
/// refresh-on-401 behaviour (a single in-flight refresh shared by every
/// concurrent 401, at most one retry per request) but reads and writes
/// only [EmployeeTokenStorage], so employee and consumer sessions never mix.
class EmployeeApiClient {
  EmployeeApiClient({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  /// Not `final` so tests can substitute a fake-backed instance.
  static EmployeeApiClient instance = EmployeeApiClient();

  final http.Client _httpClient;
  static const _timeout = Duration(seconds: 15);
  Future<bool>? _refreshFuture;

  Future<Map<String, dynamic>> get(String path) => _send('GET', path);

  Future<Map<String, dynamic>> post(String path, {Map<String, dynamic>? body, bool auth = true}) =>
      _send('POST', path, body: body, auth: auth);

  Future<Map<String, dynamic>> patch(String path, {required Map<String, dynamic> body}) =>
      _send('PATCH', path, body: body);

  Future<void> delete(String path) async {
    await _send('DELETE', path, expectBody: false);
  }

  Future<void> postNoContent(String path, {Map<String, dynamic>? body}) async {
    await _send('POST', path, body: body, expectBody: false);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
    bool expectBody = true,
    bool isRetryAfterRefresh = false,
  }) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await EmployeeTokenStorage.instance.readAccessToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;
    try {
      final request = http.Request(method, ApiConfig.resolve('/employee$path'))
        ..headers.addAll(headers)
        ..body = body != null ? jsonEncode(body) : '';
      response = await http.Response.fromStream(await _httpClient.send(request).timeout(_timeout));
    } on SocketException {
      throw ApiException.network('No connection to the ResQNet server');
    } on HttpException {
      throw ApiException.network('Could not reach the ResQNet server');
    } catch (_) {
      throw ApiException.network('Network request failed');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (!expectBody || response.body.isEmpty) return const {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }

    if (response.statusCode == 401 && auth && !isRetryAfterRefresh && await _refreshSession()) {
      return _send(method, path, body: body, auth: auth, expectBody: expectBody, isRetryAfterRefresh: true);
    }

    String code = 'UNKNOWN_ERROR';
    String message = 'Request failed (${response.statusCode})';
    try {
      final error = (jsonDecode(response.body) as Map<String, dynamic>)['error'] as Map<String, dynamic>?;
      if (error != null) {
        code = error['code'] as String? ?? code;
        message = error['message'] as String? ?? message;
      }
    } catch (_) {
      // Non-JSON error body (e.g. a proxy error page) — keep defaults.
    }
    throw ApiException(statusCode: response.statusCode, code: code, message: message);
  }

  Future<bool> _refreshSession() => _refreshFuture ??= _performRefresh().whenComplete(() => _refreshFuture = null);

  Future<bool> _performRefresh() async {
    final refreshToken = await EmployeeTokenStorage.instance.readRefreshToken();
    if (refreshToken == null) return false;
    try {
      final result = await _send('POST', '/auth/refresh', body: {'refreshToken': refreshToken}, auth: false);
      final session = result['session'] as Map<String, dynamic>;
      await EmployeeTokenStorage.instance.save(
        accessToken: session['accessToken'] as String,
        refreshToken: session['refreshToken'] as String,
      );
      return true;
    } on ApiException catch (e) {
      // Only a definitive rejection ends the session; a network failure
      // leaves the tokens in place so the portal works again once the
      // connection returns.
      if (!e.isNetworkError) await EmployeeTokenStorage.instance.clear();
      return false;
    }
  }
}
