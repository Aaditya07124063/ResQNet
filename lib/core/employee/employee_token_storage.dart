import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the employee portal's access/refresh tokens (issued by
/// POST /employee/auth/login — see backend/src/routes/employee/authRoutes.ts)
/// in the platform keychain/keystore, never in SharedPreferences.
///
/// Uses its own key namespace, separate from the consumer [TokenStorage]:
/// an employee session and a civilian session can coexist on one device and
/// neither can ever read, overwrite, or clear the other's tokens.
class EmployeeTokenStorage {
  EmployeeTokenStorage._();
  static final EmployeeTokenStorage instance = EmployeeTokenStorage._();

  final _storage = const FlutterSecureStorage();

  static const accessTokenKey = 'resqnet_employee_access_token';
  static const refreshTokenKey = 'resqnet_employee_refresh_token';

  Future<void> save({required String accessToken, required String refreshToken}) async {
    await _storage.write(key: accessTokenKey, value: accessToken);
    await _storage.write(key: refreshTokenKey, value: refreshToken);
  }

  Future<String?> readAccessToken() => _storage.read(key: accessTokenKey);
  Future<String?> readRefreshToken() => _storage.read(key: refreshTokenKey);

  Future<void> clear() async {
    await _storage.delete(key: accessTokenKey);
    await _storage.delete(key: refreshTokenKey);
  }
}
