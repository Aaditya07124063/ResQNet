import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the ResQNet backend's own access/refresh tokens (issued by
/// POST /auth/google — see backend/src/services/sessionService.ts) in the
/// platform keychain/keystore, never in SharedPreferences. These are the
/// app's only sign-in credentials (Google and phone sign-in both produce a
/// ResQNet session; there is no Firebase session).
class TokenStorage {
  TokenStorage._();
  static final TokenStorage instance = TokenStorage._();

  final _storage = const FlutterSecureStorage();

  static const _accessTokenKey = 'resqnet_access_token';
  static const _refreshTokenKey = 'resqnet_refresh_token';

  Future<void> save({required String accessToken, required String refreshToken}) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
  }
}
