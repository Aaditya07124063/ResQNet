import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'api_exception.dart';
import 'token_storage.dart';

/// Thin HTTP client for the ResQNet backend. Deliberately minimal for now
/// (Phase 4/5 needs) — auth-token refresh-on-401 and request/response
/// interceptor chaining are Phase 14 scope, not duplicated here ad hoc.
///
/// Every call goes through HTTPS in staging/production (see ApiConfig);
/// nothing here ever logs a token or request body containing secrets.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
  }) => _send('POST', path, body: body, auth: auth);

  Future<Map<String, dynamic>> get(String path, {bool auth = true}) =>
      _send('GET', path, auth: auth);

  Future<void> postNoContent(
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
  }) async {
    await _send('POST', path, body: body, auth: auth, expectBody: false);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
    bool expectBody = true,
  }) async {
    final uri = ApiConfig.resolve(path);
    final headers = {'Content-Type': 'application/json'};

    if (auth) {
      final token = await TokenStorage.instance.readAccessToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;
    try {
      final request = http.Request(method, uri)
        ..headers.addAll(headers)
        ..body = body != null ? jsonEncode(body) : '';
      final streamed = await request.send().timeout(_timeout);
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
}
