/// Backend base URL per environment.
///
/// Decision (2026-09-04): the production domain is deliberately deferred
/// until closer to app store / Play Store submission — until then, `vps`
/// points directly at the Hostinger VPS's IP:port over plain HTTP for
/// testing. `production` still requires a real HTTPS domain (see
/// docs/AUDIT.md open questions) — plain-IP HTTP is fine for pre-release
/// testing, not for a build that will ship to real users' devices, so that
/// guard stays in place rather than being relaxed to match.
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
        throw UnsupportedError(
          'Production backend URL is not configured yet — needs a real HTTPS '
          'domain before shipping to real users, deliberately deferred until '
          'closer to app store / Play Store submission. See docs/AUDIT.md.',
        );
    }
  }

  static Uri resolve(String path) => Uri.parse('$baseUrl/api/v1$path');
}
