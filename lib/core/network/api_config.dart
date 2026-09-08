/// Backend base URL per environment.
///
/// Decision (2026-09-05): production is now live at https://api.resqnet.co
/// (verified via GET /health -> {"status":"ok","env":"production"}). `vps`
/// is kept for direct IP:port testing against the Hostinger VPS ahead of a
/// domain being available for a given build/environment.
enum ResQNetEnvironment { development, vps, production }

class ApiConfig {
  const ApiConfig._();

  /// Selectable at build time with --dart-define=API_ENV=vps (or
  /// `production`) so a test/beta build doesn't require hand-editing this
  /// source file — defaults to `development` when omitted. (Dart's const
  /// evaluator doesn't allow a switch/if here, hence the nested ternary.)
  static const String _rawEnv = String.fromEnvironment('API_ENV', defaultValue: 'development');
  static const ResQNetEnvironment current = _rawEnv == 'vps'
      ? ResQNetEnvironment.vps
      : _rawEnv == 'production'
          ? ResQNetEnvironment.production
          : ResQNetEnvironment.development;

  static String get baseUrl {
    switch (current) {
      case ResQNetEnvironment.development:
        // Android emulator's alias for the host machine's localhost.
        // Override at run time with --dart-define=API_BASE_URL=... for a
        // physical device pointed at a LAN-reachable dev backend.
        return const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'http://10.0.2.2:4000',
        );
      case ResQNetEnvironment.vps:
        // Direct IP:port testing against the deployed VPS backend, no
        // domain/TLS yet. Always pass this explicitly — there is no
        // sensible default, and a wrong guess here would silently point
        // the app at nothing.
        const url = String.fromEnvironment('API_BASE_URL');
        if (url.isEmpty) {
          throw UnsupportedError(
            'ResQNetEnvironment.vps requires --dart-define=API_BASE_URL=http://<vps-ip>:<port>',
          );
        }
        return url;
      case ResQNetEnvironment.production:
        // Override with --dart-define=API_BASE_URL=... only if the
        // production domain ever needs to change; the live backend is at
        // https://api.resqnet.co by default.
        return const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'https://api.resqnet.co',
        );
    }
  }

  // Application routes are mounted under /api/v1 on the backend (see
  // backend/src/app.ts: app.use('/api/v1', ..., router)) — verified
  // directly against the running production container (2026-09-05):
  // GET /api/v1/me -> 401 malformed-auth-header (valid route), while
  // GET /me -> 404. /health is the one route mounted outside /api/v1 and
  // is not fetched through this method. Callers pass a leading-slash path
  // (e.g. '/auth/google'), so this prefixes, it doesn't just concatenate.
  static Uri resolve(String path) => Uri.parse('$baseUrl/api/v1$path');
}
