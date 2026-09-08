import 'api_client.dart';
import 'jwt_utils.dart';
import 'token_storage.dart';

/// Phase 4A: the backend session-state foundation. Deliberately standalone
/// (no Firebase dependency at all) so it's usable — and testable — on its
/// own, ahead of Phase 4B/4C wiring this into `_AuthGate`
/// (lib/app.dart). Nothing here touches Firebase or the existing UI.
class BackendSession {
  const BackendSession._();

  /// Desired behavior (see the app-start flow in the Phase 4A brief):
  ///   - no stored session at all -> not authenticated
  ///   - a stored access token that isn't (locally, per its own `exp`
  ///     claim) expired yet -> authenticated, no network call needed
  ///   - an expired/missing access token but a stored refresh token ->
  ///     attempt exactly one refresh; its result decides the outcome
  ///   - refresh fails -> local session already cleared by ApiClient,
  ///     not authenticated
  static Future<bool> restore() async {
    final accessToken = await TokenStorage.instance.readAccessToken();
    if (accessToken != null && !isJwtExpired(accessToken)) {
      return true;
    }

    final refreshToken = await TokenStorage.instance.readRefreshToken();
    if (refreshToken == null) {
      return false;
    }

    return ApiClient.instance.refreshSession();
  }
}
