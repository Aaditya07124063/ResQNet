import 'dart:convert';

/// Best-effort, LOCAL-ONLY check of a JWT's `exp` claim — this never
/// verifies the token's signature (the backend is the only party that
/// actually verifies these tokens; this is purely a client-side hint to
/// avoid an unnecessary network round trip at startup). A malformed or
/// unreadable token is always treated as expired, never as valid, so a
/// decoding failure can't accidentally report a session as still good.
bool isJwtExpired(String token, {Duration leeway = const Duration(seconds: 30)}) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return true;

    final payloadJson = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;

    final exp = payload['exp'];
    if (exp is! int) return true;

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    return DateTime.now().toUtc().isAfter(expiresAt.subtract(leeway));
  } catch (_) {
    return true;
  }
}
