/// Typed exception for ResQNet backend API failures. Mirrors the backend's
/// error response shape (`{"error": {"code", "message"}}` — see
/// backend/src/middleware/errorHandler.ts) so callers can branch on `code`
/// instead of parsing message strings.
class ApiException implements Exception {
  final int statusCode;
  final String code;
  final String message;

  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  /// No response reached the server at all (offline, DNS failure, timeout).
  /// Distinct from a real backend error — callers use this to decide
  /// whether to fall back to local/offline behavior instead of surfacing
  /// a hard error, matching the project's offline-first requirement.
  factory ApiException.network(String message) =>
      ApiException(statusCode: 0, code: 'NETWORK_ERROR', message: message);

  bool get isNetworkError => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}
