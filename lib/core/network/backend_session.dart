import 'api_client.dart';
import 'jwt_utils.dart';
import 'token_storage.dart';

/// Startup restoration of the ResQNet backend session (the app's only
/// session), used by BackendSessionController and the auth gate.
class BackendSession {
  const BackendSession._();

  /// Desired behavior (see the app-start flow in the Phase 4A brief):
  ///   - no stored session at all -> not authenticated
  ///   - a stored access token that isn't (locally, per its own `exp`
  ///     claim) expired yet -> authenticated, no network call needed
  ///   - an expired/missing access token but a stored refresh token ->
  ///     attempt exactly one refresh; its result decides the outcome
  ///   - refresh rejected by the server -> local session already cleared
  ///     by ApiClient, not authenticated
  ///   - refresh impossible because the server is unreachable -> stays
  ///     authenticated (offline); tokens are kept
  static Future<bool> restore() async {
    final accessToken = await TokenStorage.instance.readAccessToken();
    if (accessToken != null && !isJwtExpired(accessToken)) {
      return true;
    }

    final refreshToken = await TokenStorage.instance.readRefreshToken();
    if (refreshToken == null) {
      return false;
    }

    // Offline with an expired access token: the stored refresh token is
    // still valid as far as we know, so the user stays signed in and the
    // next online request refreshes it. Only a server rejection ends it.
    return await ApiClient.instance.refreshSessionOutcome() != RefreshOutcome.rejected;
  }
}
