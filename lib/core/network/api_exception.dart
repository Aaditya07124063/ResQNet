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

  /// A response DID reach us, but the backend itself failed (5xx) — a
  /// deploy in progress, a transient database outage, an unhandled
  /// server exception, etc. Distinct from [isNetworkError] (no response
  /// at all) AND from a 4xx (a definitive rejection of THIS request's
  /// content, e.g. invalid signature/revoked key/malformed body, which
  /// retrying verbatim would never fix). Callers must treat this the
  /// same as a network error for retry purposes: transient, not
  /// terminal.
  bool get isServerError => statusCode >= 500;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}
