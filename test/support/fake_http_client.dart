import 'dart:convert';
import 'package:http/http.dart' as http;

/// A hand-rolled fake `http.Client` (no mocking package is a dev
/// dependency in this project) that hands requests to a caller-supplied
/// handler and records every request sent, for assertions.
///
/// Extends `BaseClient`, not `Client` directly — in the installed http
/// package version, `Client` is an interface class that can't be
/// subclassed outside its own library; `BaseClient` is the package's own
/// documented extension point for exactly this (it implements every
/// convenience method in terms of the single `send()` this overrides).
class FakeHttpClient extends http.BaseClient {
  FakeHttpClient(this._handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return _handler(request);
  }

  @override
  void close() {}
}

http.StreamedResponse jsonStreamedResponse(int statusCode, Map<String, dynamic> body) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}

http.StreamedResponse emptyStreamedResponse(int statusCode) {
  return http.StreamedResponse(const Stream.empty(), statusCode);
}

Map<String, dynamic> fakeSession({String access = 'access', String refresh = 'refresh'}) => {
  'session': {
    'accessToken': access,
    'accessTokenExpiresAt': DateTime.now().add(const Duration(minutes: 15)).toIso8601String(),
    'refreshToken': refresh,
    'refreshTokenExpiresAt': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
  },
};
