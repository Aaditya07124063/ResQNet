import 'dart:convert';

/// Best-effort, LOCAL-ONLY check of a JWT's `exp` claim — this never
/// verifies the token's signature (the backend is the only party that
/// actually verifies these tokens; this is purely a client-side hint to
/// avoid an unnecessary network round trip at startup). A malformed or
/// unreadable token is always treated as expired, never as valid, so a
/// decoding failure can't accidentally report a session as still good.
bool isJwtExpired(String token,
    {Duration leeway = const Duration(seconds: 30)}) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return true;

    final payloadJson =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;

    final exp = payload['exp'];
    if (exp is! int) return true;

    final expiresAt =
        DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    return DateTime.now().toUtc().isAfter(expiresAt.subtract(leeway));
  } catch (_) {
    return true;
  }
}

/// Best-effort, LOCAL-ONLY read of a JWT's `sub` (subject) claim — the
/// ResQNet backend's own user id (see backend/src/services/sessionService.ts's
/// `AccessTokenPayload`). Same caveat as [isJwtExpired]: this never
/// verifies the token's signature, so it must never be used for
/// authorization — only for local display/attribution purposes (e.g. an
/// outgoing mesh message's senderId) where the backend itself is not the
/// one relying on the value. Returns null for anything that doesn't
/// decode cleanly, never throws.
String? jwtSubject(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;

    final payloadJson =
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;

    final sub = payload['sub'];
    return sub is String ? sub : null;
  } catch (_) {
    return null;
  }
}
